import XCTest
@testable import Engine

/// LM stub: scores from a closure.
final class FakeLm: LmScorer {
    let f: ([LmReq]) -> [Double]
    var seen = 0
    init(_ f: @escaping ([LmReq]) -> [Double]) { self.f = f }
    func score(_ reqs: [LmReq]) throws -> [Double] { seen = reqs.count; return f(reqs) }
    /// likes exactly the given continuations
    static func liking(_ liked: String...) -> FakeLm {
        FakeLm { reqs in reqs.map { r in liked.contains { r.cont.hasSuffix($0) } ? -1.0 : -12.0 } }
    }
}

final class CorrectorTests: XCTestCase {
    let p = DecodeParams(lam: 1.25, bias: 0, margin: 0, lamR: 1.25)
    func corr(_ cfg: CorrectorConfig = CorrectorConfig(), user: UserData? = nil) -> Corrector {
        Corrector(gen: Fixtures.gen, gen2: Fixtures.gen2, config: cfg, user: user)
    }

    func testLmOnlyScoresTopK() throws {
        let lm = FakeLm { Array(repeating: -5.0, count: $0.count) }
        let r = try corr().correctWord(WordInput(typed: "thnaks", left: "hey", sep: " "), scorer: lm, params: p, prev: nil)
        XCTAssertTrue((7...12).contains(lm.seen), "scored \(lm.seen)")
        XCTAssertEqual(lm.seen, r.nScored)
        XCTAssertTrue(r.slot.cands.contains("thnaks"))
    }

    func testConfidentExactHitSkipsLm() throws {
        let c = corr()
        let r = try c.correctWord(WordInput(typed: "because", left: "", sep: ""), scorer: FakeLm { _ in XCTFail("LM should be skipped"); return [] },
                                  params: p, prev: nil)
        XCTAssertTrue(r.skipped); XCTAssertEqual(r.out, "because")
        let r2 = try c.correctWord(WordInput(typed: "there", left: "over", sep: " "), scorer: FakeLm.liking(" there"), params: p, prev: nil)
        XCTAssertFalse(r2.skipped)
        XCTAssertEqual(c.stats.lmSkipped, 1)
    }

    func testFixesTypoWithLm() throws {
        let r = try corr().correctWord(WordInput(typed: "teh", left: "i saw", sep: " "), scorer: FakeLm.liking(" the"), params: p, prev: nil)
        XCTAssertEqual(r.out, "the")
        let cap = try corr().correctWord(WordInput(typed: "Teh", left: "", sep: ""), scorer: FakeLm.liking("The"), params: p, prev: nil)
        XCTAssertEqual(cap.out, "The")
    }

    func testCheapPathWithoutModel() throws {
        let t = KeyGeom.keyTouches("th") + [Touch(x: 2.1, y: 0.7)]
        let r = try corr().correctWord(WordInput(typed: "thw", touches: t, left: "", sep: ""), scorer: nil, params: p, prev: nil)
        XCTAssertTrue(r.cheap); XCTAssertEqual(r.out, "the")
        let keep = try corr().correctWord(WordInput(typed: "hello", left: "", sep: ""), scorer: nil, params: p, prev: nil)
        XCTAssertEqual(keep.out, "hello")
    }

    func testRecheckAndMerge() throws {
        let c = corr()
        let prevSlot = c.candidates("some", nil)
        let prev = PrevWord(slot: prevSlot, idx: prevSlot.typedIdx, left: "i need", sep: " ", lmScored: true)
        let r = try c.correctWord(WordInput(typed: "thing", left: "i need some", sep: " "), scorer: FakeLm.liking(" something"), params: p,
                                  prev: prev, merge: MergeInput(prevTyped: "some"))
        XCTAssertEqual(r.merge?.to, "something")
        let r2 = try c.correctWord(WordInput(typed: "thing", left: "i need some", sep: " "), scorer: FakeLm.liking(" some thing", " thing"),
                                   params: p, prev: prev, merge: MergeInput(prevTyped: "some"))
        XCTAssertNil(r2.merge)
    }

    func testRecheckFlipsPreviousWord() throws {
        let c = corr()
        let ps = c.candidates("there", nil)
        let prev = PrevWord(slot: ps, idx: ps.typedIdx, left: "i like", sep: " ", lmScored: true)
        // the LM only likes "their" when followed by "car" ("cxr" so the word isn't a confident skip)
        let lm = FakeLm { reqs in reqs.map { $0.cont.hasSuffix(" their car") || $0.cont == " car" ? -1.0 : -40.0 } }
        let r = try c.correctWord(WordInput(typed: "cxr", left: "i like there", sep: " "), scorer: lm, params: p, prev: prev)
        XCTAssertEqual(r.out, "car")
        XCTAssertEqual(r.recheck?.to, "their")
    }

    func testV2SplitsAndContractions() {
        let c = corr()
        XCTAssertTrue(c.candidates("inaminute", nil).cands.contains("in a minute"))
        let im = c.candidates("im", nil)
        XCTAssertTrue(im.cands.contains("i'm"))
        XCTAssertFalse(c.canSkip(im))
    }

    func testPersonalDictionaryAndSuppression() throws {
        var t = 1000.0
        let u = UserData(dict: nil, learn: nil, now: { t })
        u.add("Kubernetes")
        let c = corr(user: u)
        let r = try c.correctWord(WordInput(typed: "kubernetes", left: "", sep: ""), scorer: FakeLm.liking(" nothing"), params: p, prev: nil)
        XCTAssertEqual(r.out, "kubernetes")
        // near-miss typo of a dictionary word becomes a candidate
        XCTAssertTrue(c.candidates("kubernets", nil).cands.contains("Kubernetes"))
        // a suppressed edit needs 3 nats more: make "the" win by 1.5
        let w = WordInput(typed: "teh", left: "a", sep: " ")
        let r0 = try c.correctWord(w, scorer: FakeLm { reqs in reqs.map { $0.cont == " the" ? -2.0 : ($0.cont == " teh" ? -9.0 : -40.0) } },
                                   params: p, prev: nil)
        XCTAssertEqual(r0.out, "the")
        let gap = r0.scores[r0.slot.cands.firstIndex(of: "the")!] - r0.scores[r0.slot.cands.firstIndex(of: "teh")!]
        let lm = FakeLm { reqs in reqs.map { $0.cont == " the" ? -2.0 : ($0.cont == " teh" ? -9.0 + (gap - 1.5) / 1.25 : -40.0) } }
        XCTAssertEqual(try c.correctWord(w, scorer: lm, params: p, prev: nil).out, "the")
        u.suppress("teh", "the")
        XCTAssertEqual(try c.correctWord(w, scorer: lm, params: p, prev: nil).out, "teh")
        t += 8 * 86_400_000
        XCTAssertEqual(try c.correctWord(w, scorer: lm, params: p, prev: nil).out, "the")
    }

    func testUserDataFiles() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ac-\(UUID().uuidString)")
        let d = dir.appendingPathComponent("dict.txt"), l = dir.appendingPathComponent("learn.tsv")
        let u = UserData(dict: d, learn: l)
        XCTAssertTrue(u.add("Zorblax"))
        XCTAssertFalse(u.add("two words"))
        u.suppress("its", "it's")
        let u2 = UserData(dict: d, learn: l)
        XCTAssertTrue(u2.has("zorblax"))
        XCTAssertEqual(u2.penalty("its", "it's"), UserData.SUPPRESS_NATS)
        u2.remove("Zorblax")
        XCTAssertFalse(UserData(dict: d, learn: l).has("zorblax"))
        try? FileManager.default.removeItem(at: dir)
    }
}
