import XCTest
@testable import Engine

final class CandidateTests: XCTestCase {
    private func sameScores(_ exp: [Double], _ got: [Double], _ what: String, tol: Double = 2e-3) -> Bool {
        guard exp.count == got.count else { XCTFail("\(what): \(exp.count) vs \(got.count) scores"); return false }
        for i in exp.indices where abs(exp[i] - got[i]) > tol { XCTFail("\(what) [\(i)]: \(exp[i]) vs \(got[i])"); return false }
        return true
    }

    /// Python v1 candidate lists on key-centre touches (typing37k-style), 50 messages / 1308 words.
    func testKeyCentreSlotsMatchPython() {
        let ref = Fixtures.pipelineRef
        let texts = ref["texts"] as! [String]
        let cands = ref["cands"] as! [[[String: Any]]]
        var n = 0, ties = 0, fails = 0
        for (m, t) in texts.enumerated() {
            let words = segment(t).1
            XCTAssertEqual(cands[m].count, words.count)
            for (i, w) in words.enumerated() {
                let e = cands[m][i]
                var tc = KeyGeom.keyTouches(w)
                if tc.isEmpty { tc = KeyGeom.keyTouches("a") }
                let slot = Slot.of(w, Fixtures.gen.generate(tc, w))
                // numpy's argsort isn't stable: exact ties may come in either order -> same score per position + same set
                let ec = e["cands"] as! [String]
                if ec != slot.cands {
                    if Set(ec) != Set(slot.cands) { fails += 1; if fails < 5 { XCTFail("cands of '\(w)': \(slot.cands) vs \(ec)") } } else { ties += 1 }
                }
                if !sameScores((e["sp"] as! [NSNumber]).map { $0.doubleValue }, slot.sp, "sp of '\(w)'") { fails += 1 }
                XCTAssertEqual((e["typed_idx"] as! NSNumber).intValue, slot.typedIdx, "typed_idx of '\(w)'")
                n += 1
            }
        }
        print("key-centre slots: \(n) words, \(ties) exact ties in another order, \(fails) failures")
        XCTAssertEqual(fails, 0)
        XCTAssertLessThan(ties * 50, n)
    }

    /// Jittered real-valued touches -> v1 and v2 lists with the same order, kinds and spatial scores as Python.
    func testRealTouchesMatchPython() {
        let f = Fixtures.json("cands_touch.json") as! [String: Any]
        var n = 0
        for o in f["cases"] as! [[String: Any]] {
            let typed = o["typed"] as! String
            let tc = (o["touches"] as! [[NSNumber]]).map { Touch(x: $0[0].doubleValue, y: $0[1].doubleValue) }
            let v1 = Fixtures.gen.generate(tc, typed)
            let e1 = o["v1"] as! [[Any]]
            XCTAssertEqual(e1.map { $0[0] as! String }, v1.map { $0.text }, "v1 cands of '\(typed)'")
            _ = sameScores(e1.map { ($0[1] as! NSNumber).doubleValue }, v1.map { $0.sp }, "v1 sp of '\(typed)'", tol: 1e-6)
            let v2 = Fixtures.gen2.generate(tc, typed)
            let e2 = o["v2"] as! [[Any]]
            XCTAssertEqual(e2.map { $0[0] as! String }, v2.map { $0.text }, "v2 cands of '\(typed)'")
            XCTAssertEqual(e2.map { $0[2] as! String }, v2.map { $0.kind }, "v2 kinds of '\(typed)'")
            _ = sameScores(e2.map { ($0[1] as! NSNumber).doubleValue }, v2.map { $0.sp }, "v2 sp of '\(typed)'", tol: 1e-6)
            n += 1
        }
        for o in f["merges"] as! [[String: Any]] {
            let a = o["a"] as! String, b = o["b"] as! String
            XCTAssertEqual(o["ok"] as! Bool, Fixtures.gen2.mergeOk(a, b), "mergeOk \(a) \(b)")
            let got = Fixtures.gen2.mergeCandidates(KeyGeom.keyTouches(a), a, KeyGeom.keyTouches(b), b)
            let exp = o["cands"] as! [[Any]]
            XCTAssertEqual(exp.map { $0[0] as! String }, got.map { $0.text }, "merge \(a) \(b)")
            _ = sameScores(exp.map { ($0[1] as! NSNumber).doubleValue }, got.map { $0.sp }, "merge sp \(a) \(b)", tol: 1e-6)
        }
        print("real-touch cases: \(n)")
    }

    func testSpatialPrefersNearKeys() {
        let sp = SpatialModel()
        let e = sp.emitTable(KeyGeom.keyTouches("the"))
        let the = sp.score(e, sp.wordCode("the")!)
        let tge = sp.score(e, sp.wordCode("tge")!)
        let xyz = sp.score(e, sp.wordCode("xyz")!)
        XCTAssertTrue(the > tge && tge > xyz)
        XCTAssertLessThan(abs(the - 3 * sp.perfectLetter), 0.05)
        XCTAssertTrue(Fixtures.gen.generate(KeyGeom.keyTouches("qzx"), "qzx").contains { $0.text == "qzx" })
    }

    func testApplyCaseAndRound() {
        XCTAssertEqual(applyCase("the", "Teh"), "The")
        XCTAssertEqual(applyCase("the", "TEH"), "THE")
        XCTAssertEqual(applyCase("the", "teh"), "the")
        XCTAssertEqual(applyCase("i'm", "Im"), "I'm")
        XCTAssertEqual(round3(1.2345), 1.234)   // 1.2345 is just below the tie in binary
        XCTAssertEqual(round3(-4.0015), -4.002)
        XCTAssertEqual(round3(0.0625), 0.062)   // exact tie -> even
    }

    func testSegment() {
        let (seps, words) = segment("I've got it, don't  worry!")
        XCTAssertEqual(words, ["I've", "got", "it", "don't", "worry"])
        XCTAssertEqual(seps, ["", " ", " ", ", ", "  ", "!"])
    }
}
