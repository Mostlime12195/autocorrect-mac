import Engine
import Foundation

/// `Autocorrect --selftest <model dir>`: the bundled app end to end without the UI (CI runs it on the built .app):
/// lexicon from the bundle, onnxruntime from Contents/Frameworks, the model from the dir (manifest.json + files).
enum SelfTest {
    static func run(_ args: [String]) -> Int32 {
        guard let i = args.firstIndex(of: "--selftest"), i + 1 < args.count else { print("usage: --selftest <model dir>"); return 2 }
        let dir = URL(fileURLWithPath: args[i + 1])
        do {
            print("onnxruntime \(OrtSessionHandle.ortVersion)")
            guard let lexURL = Bundle.main.url(forResource: "lexicon", withExtension: "tsv") else { print("FAIL: no lexicon.tsv in bundle"); return 1 }
            var t0 = Date()
            let lex = try Lexicon(path: lexURL.path)
            let gen = CandidateGenerator(lex: lex, sp: SpatialModel(sigma: 0.3))
            let corr = Corrector(gen: gen, gen2: CandidateGeneratorV2(gen: gen))
            print(String(format: "lexicon %d words + generators in %.2f s", lex.size, Date().timeIntervalSince(t0)))
            let manifest = try Manifest.parse(Data(contentsOf: dir.appendingPathComponent("manifest.json")))
            var failed = 0
            for spec in manifest.models {
                let g = dir.appendingPathComponent(spec.graph.file), v = dir.appendingPathComponent(spec.vocab.file)
                guard FileManager.default.fileExists(atPath: g.path) else { print("skip \(spec.id): no \(spec.graph.file)"); continue }
                t0 = Date()
                let step = try StepModel.open(path: g.path, meta: spec.meta, threads: 4)
                let sc = NeuralScorer(tok: try SPTokenizer.fromJSON(Data(contentsOf: v)), step: step, styleId: spec.styleToken)
                print(String(format: "%@: session in %.2f s", spec.id, Date().timeIntervalSince(t0)))
                // type each sentence through the same state machine the app uses
                let cases = [("i thnik it is going to rain tomorow ", "I think it is going to rain tomorrow "),
                             ("can you send me teh file ", "can you send me the file "),
                             ("thanks for the help ", "thanks for the help ")]
                for (typed, want) in cases {
                    let core = TypingCore()
                    var shown = ""
                    var ms: [Double] = []
                    for c in typed {
                        switch core.key(.text(String(c)), canCorrect: true) {
                        case .pass: shown.append(c)
                        case .hold(let job):
                            let r = try corr.correctWord(job.input, scorer: sc, params: spec.standardParams, prev: job.prev, merge: job.merge)
                            ms.append(r.ms)
                            if let inj = core.resolve(job, r) { shown = String(shown.dropLast(inj.deletes)) + inj.text }
                            shown += job.sep
                        case .undo: break
                        }
                    }
                    let ok = shown == want
                    if !ok { failed += 1 }
                    print("  \(ok ? "ok  " : "FAIL") '\(typed)' -> '\(shown)' (want '\(want)'); ms/word \(ms.map { String(format: "%.0f", $0) }.joined(separator: " "))")
                }
                step.close()
            }
            return failed == 0 ? 0 : 1
        } catch {
            print("FAIL: \(error)")
            return 1
        }
    }
}
