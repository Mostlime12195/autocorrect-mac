import XCTest
@testable import Engine

/// The real .ort step graphs through onnxruntime: decode the reference messages and compare with the Python decoder
/// (corrector.decode, system e) on the same graphs. Needs AC_MODEL_DIR with lm_block4.step.int8.ort and
/// m2s.step.int4m.ort (CI downloads them from the models release).
final class DecoderParityTests: XCTestCase {
    static let block4Meta = StepMeta(nKvHeads: 2, headDim: 64, convKernel: 7, dModel: 384,
                                     stateNames: (0..<5).flatMap { ["k\($0)", "v\($0)"] } + (0..<9).map { "c\($0)" })

    private func params(_ o: [String: Any]) -> DecodeParams {
        DecodeParams(lam: (o["lam"] as! NSNumber).doubleValue, bias: (o["bias"] as! NSNumber).doubleValue,
                     margin: (o["margin"] as? NSNumber)?.doubleValue, lamR: (o["lam_r"] as? NSNumber)?.doubleValue)
    }

    /// -> (words, identical words, identical messages)
    private func run(_ msgs: [Message], _ exp: [[String]], _ step: StepModel, _ tok: SPTokenizer, _ p: DecodeParams, style: Int?,
                     label: String) throws -> (Int, Int) {
        var words = 0, same = 0, msame = 0
        let t0 = Date()
        var changed = 0, changedSame = 0
        for (i, m) in msgs.enumerated() where i < exp.count {
            let sc = NeuralScorer(tok: tok, step: step, styleId: style)   // fresh caches per message, like the reference
            let got = try Decoder.decode(m, sc, p).outs
            if got == exp[i] { msame += 1 }
            for (j, (a, b)) in zip(got, exp[i]).enumerated() {
                words += 1
                if a == b { same += 1 } else { print("  \(label) msg \(i) word \(j): typed '\(m.words[j].typed)' exp '\(b)' got '\(a)'") }
                let typed = m.words[j].cands[m.words[j].typedIdx]
                if b != typed { changed += 1; if a == b { changedSame += 1 } }
            }
        }
        let secs = Date().timeIntervalSince(t0)
        print("\(label): \(msame)/\(min(msgs.count, exp.count)) messages, \(same)/\(words) words identical; " +
              "\(changedSame)/\(changed) of the reference's corrections reproduced; \(String(format: "%.1f", secs)) s, " +
              "\(step.runs) ORT runs, \(String(format: "%.1f", 1000 * step.ortSeconds / Double(max(step.runs, 1)))) ms/run")
        return (words, same)
    }

    /// block4 (m1 34M int8): the Android engine's reference (Python decode on the int8 graph), 1308 words.
    func testBlock4MatchesPython() throws {
        let path = try Fixtures.modelPath("lm_block4.step.int8.ort")
        let step = try StepModel.open(path: path, meta: Self.block4Meta, threads: 2)
        defer { step.close() }
        let ref = Fixtures.pipelineRef
        let e = ((ref["params"] as! [String: Any])["lm_block4"] as! [String: Any])["e"] as! [String: Any]
        let exp = (ref["outs"] as! [String: Any])["lm_block4"] as! [[String]]
        let (words, same) = try run(Fixtures.messages(ref), exp, step, Fixtures.tokM1, params(e), style: nil, label: "block4 int8")
        XCTAssertGreaterThan(words, 1000)
        // int8 dynamic-quant kernels differ between CPUs (x86 VNNI / ARM dotprod): near-ties may flip; allow 1%
        XCTAssertLessThanOrEqual((words - same) * 100, words, "too many word differences: \(words - same)/\(words)")
    }

    /// m2s int4 (MatMulNBits, the default model) with the standard style token: Python decode on the same .ort graph.
    func testM2sInt4MatchesPython() throws {
        let path = try Fixtures.modelPath("m2s.step.int4m.ort")
        let ref = Fixtures.json("pipeline_m2s.json") as! [String: Any]
        let m = ref["meta"] as! [String: Any]
        let meta = StepMeta(nKvHeads: (m["n_kv_heads"] as! NSNumber).intValue, headDim: (m["head_dim"] as! NSNumber).intValue,
                            convKernel: (m["conv_kernel"] as! NSNumber).intValue, dModel: (m["d_model"] as! NSNumber).intValue,
                            stateNames: m["state_names"] as! [String])
        let step = try StepModel.open(path: path, meta: meta, threads: 2)
        defer { step.close() }
        let exp = ref["outs"] as! [[String]]
        let (words, same) = try run(Fixtures.messages(Fixtures.pipelineRef), exp, step, Fixtures.tokM2,
                                    params(ref["params"] as! [String: Any]), style: (ref["style_id"] as! NSNumber).intValue, label: "m2s int4")
        XCTAssertGreaterThan(words, 300)
        XCTAssertLessThanOrEqual((words - same) * 100, words, "too many word differences: \(words - same)/\(words)")
    }

    /// Cached-prefix extension gives (about) the same scores as a fresh full-context run.
    func testPrefixExtensionMatchesFreshRun() throws {
        let path = try Fixtures.modelPath("lm_block4.step.int8.ort")
        let step = try StepModel.open(path: path, meta: Self.block4Meta, threads: 2)
        defer { step.close() }
        let left1 = "hey are you coming to the"
        let left2 = left1 + " party tonight or"
        let reqs = ["not", "nit", "now"].map { LmReq(left2, " " + $0) }
        let fresh = try NeuralScorer(tok: Fixtures.tokM1, step: step).score(reqs)
        let warm = NeuralScorer(tok: Fixtures.tokM1, step: step)
        try warm.warm(left1)
        let ext = try warm.score(reqs)
        for i in reqs.indices { XCTAssertEqual(fresh[i], ext[i], accuracy: 1.0) }
        XCTAssertEqual(fresh.indices.max { fresh[$0] < fresh[$1] }, ext.indices.max { ext[$0] < ext[$1] })
        let styled = try NeuralScorer(tok: Fixtures.tokM1, step: step, styleId: 250).score(reqs)
        XCTAssertTrue(styled.allSatisfy { $0.isFinite })
        print("onnxruntime \(OrtSessionHandle.ortVersion); fresh \(fresh) ext \(ext)")
    }

    /// The app's word-at-a-time corrector (battery rules: top-K subset, skips, re-check subset) on the real m2s graph
    /// mostly agrees with the full Python decode.
    func testCorrectorAgreesWithFullDecode() throws {
        let path = try Fixtures.modelPath("m2s.step.int4m.ort")
        let ref = Fixtures.json("pipeline_m2s.json") as! [String: Any]
        let m = ref["meta"] as! [String: Any]
        let meta = StepMeta(nKvHeads: (m["n_kv_heads"] as! NSNumber).intValue, headDim: (m["head_dim"] as! NSNumber).intValue,
                            convKernel: (m["conv_kernel"] as! NSNumber).intValue, dModel: (m["d_model"] as! NSNumber).intValue,
                            stateNames: m["state_names"] as! [String])
        let step = try StepModel.open(path: path, meta: meta, threads: 2)
        defer { step.close() }
        let exp = ref["outs"] as! [[String]]
        let p = params(ref["params"] as! [String: Any])
        let corr = Corrector(gen: Fixtures.gen)   // v1 candidates, like the reference slots
        let texts = Fixtures.pipelineRef["texts"] as! [String]
        var words = 0, same = 0
        var ms: [Double] = []
        for (i, t) in texts.enumerated() where i < exp.count {
            let sc = NeuralScorer(tok: Fixtures.tokM2, step: step, styleId: (ref["style_id"] as! NSNumber).intValue)
            let (seps, typed) = segment(t)
            var outs: [String] = []
            var prev: (WordResult, Int)? = nil
            for (j, w) in typed.enumerated() {
                let left = zip(seps.prefix(j), outs).map { $0 + $1 }.joined()
                var pw: PrevWord? = nil
                if let (r, pj) = prev, pj == j - 1 {
                    let leftp = zip(seps.prefix(j - 1), outs).map { $0 + $1 }.joined()
                    pw = PrevWord(slot: r.slot, idx: r.chosen, left: leftp, sep: seps[j - 1], lmScored: r.lmScored,
                                  margin: r.lmScored ? r.margin : 0, scores: r.lmScored ? r.scores : nil)
                }
                let r = try corr.correctWord(WordInput(typed: w, left: left, sep: seps[j]), scorer: sc, params: p, prev: pw)
                ms.append(r.ms)
                if let rc = r.recheck { outs[j - 1] = rc.to }
                outs.append(r.out)
                prev = (r, j)
            }
            for (a, b) in zip(outs, exp[i]) { words += 1; if a == b { same += 1 } }
        }
        ms.sort()
        print("corrector vs full decode (m2s): \(same)/\(words) words identical; per word p50 \(ms[ms.count / 2]) ms, p90 \(ms[ms.count * 9 / 10]) ms, max \(ms.last!) ms")
        XCTAssertGreaterThanOrEqual(Double(same) / Double(words), 0.97)
    }
}
