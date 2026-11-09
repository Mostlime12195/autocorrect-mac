import Engine
import Foundation
import os

/// The decoder and its model session. Everything engine-side runs on one serial queue (never the event-tap thread);
/// session creation runs on a loader queue and is swapped in on the engine queue.
final class EngineHost {
    let queue = DispatchQueue(label: "ac.engine", qos: .userInteractive)
    private let loadQueue = DispatchQueue(label: "ac.load", qos: .utility)
    private let log = Logger(subsystem: "dev.mostlime.autocorrect-mac", category: "engine")

    // engine queue only
    private var corrector: Corrector?
    private var scorer: NeuralScorer?
    private var params = DecodeParams.fallback

    // any thread
    private let stateLock = NSLock()
    private var _ready = false
    private var _status = "Starting…"
    private var _modelLabel = ""
    private var _lastMs = 0.0

    var ready: Bool { stateLock.lock(); defer { stateLock.unlock() }; return _ready }
    var status: String { stateLock.lock(); defer { stateLock.unlock() }; return _status }
    var modelLabel: String { stateLock.lock(); defer { stateLock.unlock() }; return _modelLabel }
    var lastMs: Double { stateLock.lock(); defer { stateLock.unlock() }; return _lastMs }
    var onChange: (() -> Void)?

    let user: UserData

    init(user: UserData) { self.user = user }

    func setStatus(_ s: String, ready r: Bool? = nil) {
        stateLock.lock(); _status = s; if let r = r { _ready = r }; stateLock.unlock()
        DispatchQueue.main.async { self.onChange?() }
    }

    /// Lexicon + candidate generators (engine queue).
    func start(lexicon: URL) {
        queue.async {
            let t0 = Date()
            do {
                let lex = try Lexicon(path: lexicon.path)
                let gen = CandidateGenerator(lex: lex, sp: SpatialModel(sigma: 0.3))
                self.corrector = Corrector(gen: gen, gen2: CandidateGeneratorV2(gen: gen), user: self.user)
                self.log.info("lexicon \(lex.size) words in \(Date().timeIntervalSince(t0))s")
            } catch {
                self.setStatus("Lexicon failed: \(error)", ready: false)
            }
        }
    }

    /// engine queue only
    func inLexiconOnQueue(_ w: String) -> Bool { corrector?.lex.index[w.lowercased()] != nil }

    /// Open a model's session (loader queue), then swap it in and warm it up.
    func load(spec: ModelSpec, graph: URL, vocab: URL, completion: ((Error?) -> Void)? = nil) {
        setStatus("Loading \(spec.label)…", ready: false)
        loadQueue.async {
            do {
                let t0 = Date()
                let tok = try SPTokenizer.fromJSON(Data(contentsOf: vocab))
                let threads = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
                let step = try StepModel.open(path: graph.path, meta: spec.meta, threads: threads)
                let sc = NeuralScorer(tok: tok, step: step, styleId: spec.styleToken)
                // warm-up: the first ORT run allocates; do it before the first word
                _ = try sc.score([LmReq("hello there", " friend"), LmReq("hello there", " fiend")])
                sc.clearCache()
                let secs = Date().timeIntervalSince(t0)
                self.queue.async {
                    self.scorer?.step.close()
                    self.scorer = sc
                    self.params = spec.standardParams
                    self.stateLock.lock(); self._modelLabel = spec.label; self.stateLock.unlock()
                    self.setStatus("Ready · \(spec.label)", ready: true)
                    self.log.info("session \(spec.id) ready in \(secs)s, \(threads) threads")
                    completion?(nil)
                }
            } catch {
                self.setStatus("Model failed to load: \(error)", ready: false)
                self.log.error("load failed: \(String(describing: error))")
                completion?(error)
            }
        }
    }

    /// Correct one word end (engine queue). The precheck runs first on the engine queue (focused field checks via AX).
    func correct(_ job: CorrectionJob, precheck: @escaping () -> Bool, done: @escaping (WordResult?) -> Void) {
        queue.async {
            guard let c = self.corrector, let sc = self.scorer, precheck() else { done(nil); return }
            do {
                sc.lastCtxTokens = 0
                let r = try c.correctWord(job.input, scorer: sc, params: self.params, prev: job.prev, merge: job.merge)
                self.stateLock.lock(); self._lastMs = r.ms; self.stateLock.unlock()
                done(r)
            } catch {
                self.log.error("correction failed: \(String(describing: error))")
                done(nil)
            }
        }
    }

    /// Layout change: letter centres for the spatial model (engine queue).
    func setLayout(_ centers: [Character: (Double, Double)]) {
        queue.async { KeyGeom.setCenters(centers) }
    }
}
