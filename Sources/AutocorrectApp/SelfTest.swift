import Engine
import Foundation
import KeylimeCore

/// `Keylime --selftest <model dir>`: the bundled app end to end without the UI (CI runs it on the built .app):
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
                // stage (b): what a finished word does in each mode
                for (left, typed, want) in [("can you send me", "teh", "auto=apply suggest=flag"), ("thanks for the", "help", "auto=keep suggest=keep")] {
                    let r = try corr.correctWord(WordInput(typed: typed, left: left, sep: " "), scorer: sc, params: spec.standardParams, prev: nil)
                    let o = WordOutcome(r, typedOOV: lex.index[typed] == nil)
                    func name(_ m: CorrectionMode) -> String {
                        switch Policy.boundary(o, mode: m, hasPrev: false, prevOut: nil, userWord: false) {
                        case .keep: return "keep"
                        case .apply: return "apply"
                        case .flag: return "flag"
                        }
                    }
                    let got = "auto=\(name(.auto)) suggest=\(name(.suggest))"
                    let ok = got == want
                    if !ok { failed += 1 }
                    print("  \(ok ? "ok  " : "FAIL") word end '\(left) \(typed)': \(got) (want \(want)); margin \(String(format: "%.1f", o.margin))")
                }
                // non-word typos are fixed in every context; slang, names and odd casing are left alone
                let consistent: [(String, String, String?)] = [
                    ("can you", "hlep", "help"), ("I need some", "hlep", "help"), ("thanks for the", "hlep", "help"), ("", "hlep", "help"),
                    ("I went home", "isnstead", "instead"), ("use this one", "isnstead", "instead"), ("we could walk", "isnstead", "instead"),
                    ("", "Isnstead", "Instead"),
                    ("haha", "lmao", nil), ("that's so funny", "lol", nil), ("it's cold", "brrr", nil), ("I'm", "gonna", nil),
                    ("I love my", "iPhone", nil), ("I talked to", "Mazinga", nil), ("that was", "sooo", nil), ("lmao", "lllmo", nil),
                ]
                for (left, typed, want) in consistent {
                    let r = try corr.correctWord(WordInput(typed: typed, left: left, sep: left.isEmpty ? "" : " "), scorer: sc,
                                                 params: spec.standardParams, prev: nil)
                    let o = WordOutcome(r, typedOOV: lex.index[typed.lowercased()] == nil)
                    let d = Policy.boundary(o, mode: .auto, hasPrev: false, prevOut: nil, userWord: false, nameLike: Policy.nameLike(typed, left: left))
                    var got = "kept"
                    if case .apply(let out, _, _) = d { got = out } else if case .flag = d { got = "underlined" }
                    let ok = want.map { got == $0 } ?? (got == "kept" || got == "underlined")
                    if !ok { failed += 1 }
                    print("  \(ok ? "ok  " : "FAIL") auto '\(left) \(typed)' -> \(got) (want \(want ?? "left alone")); margin \(String(format: "%.1f", o.margin))")
                }
                // stage (c): the idle sentence pass, with right context
                t0 = Date()
                let fixes = try SentenceCheck.check(corr, SentenceReq(left: "", sentence: "can you send me teh file when you get a chance."),
                                                    scorer: sc, params: spec.standardParams, minGap: Policy.FLAG_MARGIN)
                let ok = fixes.contains { $0.from == "teh" && $0.to == "the" } && fixes.count <= 2
                if !ok { failed += 1 }
                print("  \(ok ? "ok  " : "FAIL") idle pass: \(fixes.map { "\($0.from)->\($0.to) (\(String(format: "%.1f", $0.gap)))" }) in \(String(format: "%.0f", Date().timeIntervalSince(t0) * 1000)) ms")
                step.close()
            }
            failed += checkPieces()
            return failed == 0 ? 0 : 1
        } catch {
            print("FAIL: \(error)")
            return 1
        }
    }

    /// marks, update manifest, this bundle's signature (the updater's identity check)
    static func checkPieces() -> Int {
        var failed = 0
        func check(_ ok: Bool, _ what: String) { if !ok { failed += 1 }; print("  \(ok ? "ok  " : "FAIL") \(what)") }
        let t = MarkTracker()
        t.add(start: 4, word: "teh", fixes: ["the"], spelling: true)
        t.reconcile("oh, see teh cat")
        check(t.marks.first?.start == 8, "marks follow the text")
        let m = #"{"version":"9.9.9","url":"https://example.com/Keylime-mac-9.9.9.zip","sha256":"\#(String(repeating: "a", count: 64))","size":1}"#
        check((try? UpdateCore.parse(Data(m.utf8)))?.version == "9.9.9" && UpdateCore.newer("9.9.9", than: Updater.currentVersion),
              "update manifest parses and is newer than \(Updater.currentVersion)")
        let req = CodeIdentity.ownRequirement() ?? "unsigned"
        print("  designated requirement: \(req)")
        let signed = !req.contains("cdhash") && req.contains("certificate leaf")
        if ProcessInfo.processInfo.environment["KL_REQUIRE_SIGNED"] == "1" {
            check(signed, "signed with the Keylime certificate")
            check(CodeIdentity.mismatch(Bundle.main.bundleURL) == nil, "this bundle passes the updater's identity check")
        }
        print("  system autocorrect is \(SystemAutocorrect.isOn ? "on" : "off")")
        return failed
    }
}
