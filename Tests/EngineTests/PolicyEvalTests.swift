import XCTest
@testable import Engine
@testable import KeylimeCore

/// Auto-apply before / after the non-word rule, on the 50 reference messages (noisy typing, m2s int4, reference
/// output = the Python decoder's). Left context = the reference text so far. Prints the numbers; asserts only that the
/// new rule fixes at least as many typos without many more wrong changes.
final class PolicyEvalTests: XCTestCase {
    func testNonWordRuleAutoApplyRate() throws {
        let path = try Fixtures.modelPath("m2s.step.int4m.ort")
        let ref = Fixtures.json("pipeline_m2s.json") as! [String: Any]
        let m = ref["meta"] as! [String: Any]
        let meta = StepMeta(nKvHeads: (m["n_kv_heads"] as! NSNumber).intValue, headDim: (m["head_dim"] as! NSNumber).intValue,
                            convKernel: (m["conv_kernel"] as! NSNumber).intValue, dModel: (m["d_model"] as! NSNumber).intValue,
                            stateNames: m["state_names"] as! [String])
        let step = try StepModel.open(path: path, meta: meta, threads: 4)
        defer { step.close() }
        let outs = ref["outs"] as! [[String]]
        let p = DecodeParams(lam: 1.25, bias: 0, margin: 0, lamR: 1.25)
        let corr = Corrector(gen: Fixtures.gen, gen2: Fixtures.gen2)
        struct Tally { var right = 0, wrong = 0, flagged = 0, kept = 0, falseApply = 0, falseFlag = 0 }
        var old = Tally(), new = Tally()
        var targets = 0, others = 0
        var changed: [String] = []
        for (i, msg) in Fixtures.messages(Fixtures.pipelineRef).enumerated() where i < outs.count {
            let sc = NeuralScorer(tok: Fixtures.tokM2, step: step, styleId: (ref["style_id"] as! NSNumber).intValue)
            var left = ""
            for (j, slot) in msg.words.enumerated() where j < outs[i].count {
                let typed = slot.typed, want = outs[i][j], sep = msg.seps[j]
                guard TypingCore.correctable(typed) else { left += sep + want; continue }
                let r = try corr.correctWord(WordInput(typed: typed, left: left, sep: sep), scorer: sc, params: p, prev: nil)
                let o = WordOutcome(r, typedOOV: Fixtures.lexicon.index[typed.lowercased()] == nil)
                let nl = Policy.nameLike(typed, left: left)
                let isTarget = want != typed
                if isTarget { targets += 1 } else { others += 1 }
                for forced in [false, true] {
                    let d = Policy.boundary(o, mode: .auto, hasPrev: false, prevOut: nil, userWord: false, nameLike: nl, forceNonWords: forced)
                    var t = forced ? new : old
                    switch d {
                    case .apply(let out, _, _):
                        if isTarget { if out == want { t.right += 1 } else { t.wrong += 1 } } else { t.falseApply += 1 }
                    case .flag: if isTarget { t.flagged += 1 } else { t.falseFlag += 1 }
                    case .keep: if isTarget { t.kept += 1 }
                    }
                    if forced { new = t } else { old = t }
                }
                let dOld = Policy.boundary(o, mode: .auto, hasPrev: false, prevOut: nil, userWord: false, nameLike: nl, forceNonWords: false)
                let dNew = Policy.boundary(o, mode: .auto, hasPrev: false, prevOut: nil, userWord: false, nameLike: nl)
                if dOld != dNew && changed.count < 25 { changed.append("'\(typed)' (want '\(want)'): \(dOld) -> \(dNew)") }
                left += sep + want
            }
        }
        func line(_ n: String, _ t: Tally) -> String {
            String(format: "%@: of %d typos %d fixed right (%.0f%%), %d fixed wrong, %d underlined, %d left; of %d correct words %d changed, %d underlined",
                   n, targets, t.right, 100 * Double(t.right) / Double(max(targets, 1)), t.wrong, t.flagged, t.kept, others, t.falseApply, t.falseFlag)
        }
        print(line("before (margin rule)", old))
        print(line("after (non-word rule)", new))
        for c in changed { print("  changed: \(c)") }
        XCTAssertGreaterThanOrEqual(new.right, old.right)
        XCTAssertLessThanOrEqual(new.falseApply, old.falseApply + 3)
    }
}
