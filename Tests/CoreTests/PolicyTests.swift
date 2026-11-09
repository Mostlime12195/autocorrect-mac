import XCTest
@testable import KeylimeCore

final class PolicyTests: XCTestCase {
    func o(_ typed: String, _ out: String, margin: Double, gap: Double, fixes: [String]? = nil, merge: String? = nil,
           recheck: String? = nil, oov: Bool = true) -> WordOutcome {
        WordOutcome(typed: typed, out: out, margin: margin, gap: gap, fixes: fixes ?? (out == typed ? [] : [out]), merge: merge,
                    recheck: recheck, typedOOV: oov)
    }

    func testConfidentFixApplies() {
        XCTAssertEqual(Policy.boundary(o("teh", "the", margin: 6, gap: 6), mode: .auto, hasPrev: false, prevOut: nil, userWord: false),
                       .apply(out: "the", prevNew: nil, merged: false))
    }

    func testUnsureFixIsUnderlinedInAutoMode() {
        XCTAssertEqual(Policy.boundary(o("form", "from", margin: 1, gap: 2, oov: false), mode: .auto, hasPrev: false, prevOut: nil, userWord: false),
                       .flag(fixes: ["from"], spelling: false))
    }

    func testWeakFixIsNeitherAppliedNorFlagged() {
        XCTAssertEqual(Policy.boundary(o("abc", "abd", margin: 0.5, gap: 1), mode: .auto, hasPrev: false, prevOut: nil, userWord: false), .keep)
    }

    func testSuggestModeNeverEdits() {
        XCTAssertEqual(Policy.boundary(o("teh", "the", margin: 9, gap: 9), mode: .suggest, hasPrev: false, prevOut: nil, userWord: false),
                       .flag(fixes: ["the"], spelling: true))
        // no "i" -> "I" either
        XCTAssertEqual(Policy.boundary(o("i", "i", margin: 9, gap: 0), mode: .suggest, hasPrev: false, prevOut: nil, userWord: false), .keep)
    }

    func testOffAndUserWords() {
        XCTAssertEqual(Policy.boundary(o("teh", "the", margin: 9, gap: 9), mode: .off, hasPrev: false, prevOut: nil, userWord: false), .keep)
        XCTAssertEqual(Policy.boundary(o("teh", "the", margin: 9, gap: 9), mode: .auto, hasPrev: false, prevOut: nil, userWord: true), .keep)
    }

    func testCapitalI() {
        XCTAssertEqual(Policy.boundary(o("i", "i", margin: 9, gap: 0), mode: .auto, hasPrev: false, prevOut: nil, userWord: false),
                       .apply(out: "I", prevNew: nil, merged: false))
        XCTAssertEqual(Policy.boundary(o("i", "i", margin: 9, gap: 0), mode: .auto, hasPrev: false, prevOut: nil, userWord: false,
                                       penalty: { _, _ in 3 }), .keep)
    }

    func testRecheckAndMergeNeedThePreviousWord() {
        let r = o("cat", "cat", margin: 9, gap: 0, recheck: "the")
        XCTAssertEqual(Policy.boundary(r, mode: .auto, hasPrev: true, prevOut: "teh", userWord: false), .apply(out: "cat", prevNew: "the", merged: false))
        XCTAssertEqual(Policy.boundary(r, mode: .auto, hasPrev: false, prevOut: nil, userWord: false), .keep)
        let m = o("thing", "thing", margin: 0.2, gap: 0, merge: "something")
        XCTAssertEqual(Policy.boundary(m, mode: .auto, hasPrev: true, prevOut: "some", userWord: false), .apply(out: "something", prevNew: nil, merged: true))
    }

    func testIdle() {
        XCTAssertEqual(Policy.idle(gap: 5, spelling: true, mode: .auto, inCurrentSentence: true, userWord: false), .apply)
        XCTAssertEqual(Policy.idle(gap: 5, spelling: true, mode: .auto, inCurrentSentence: false, userWord: false), .flag)
        XCTAssertEqual(Policy.idle(gap: 5, spelling: false, mode: .auto, inCurrentSentence: true, userWord: false), .flag)
        XCTAssertEqual(Policy.idle(gap: 3, spelling: true, mode: .auto, inCurrentSentence: true, userWord: false), .flag)
        XCTAssertEqual(Policy.idle(gap: 9, spelling: true, mode: .suggest, inCurrentSentence: true, userWord: false), .flag)
        XCTAssertEqual(Policy.idle(gap: 1, spelling: true, mode: .suggest, inCurrentSentence: true, userWord: false), .none)
        XCTAssertEqual(Policy.idle(gap: 9, spelling: true, mode: .off, inCurrentSentence: true, userWord: false), .none)
    }

    func testSpellingEdit() {
        XCTAssertTrue(Policy.isSpellingEdit("teh", "the", typedOOV: true))
        XCTAssertFalse(Policy.isSpellingEdit("form", "from", typedOOV: false))
        XCTAssertFalse(Policy.isSpellingEdit("dont", "don't", typedOOV: true))
        XCTAssertFalse(Policy.isSpellingEdit("alot", "a lot", typedOOV: true))
    }
}

final class NonWordPolicyTests: XCTestCase {
    func o(_ typed: String, _ out: String, margin: Double, fixes: [String], fixGap: Double = 5, oov: Bool = true) -> WordOutcome {
        WordOutcome(typed: typed, out: out, margin: margin, gap: 1.5, fixes: fixes, typedOOV: oov, fixGap: fixGap)
    }

    func testNonWordIsFixedWhateverTheMargin() {
        // the diag case: "underlined, 3 fixes (margin 0.1, gap 1.5)"
        XCTAssertEqual(Policy.boundary(o("hlep", "help", margin: 0.1, fixes: ["help", "held", "heap"], fixGap: 2), mode: .auto,
                                       hasPrev: false, prevOut: nil, userWord: false), .apply(out: "help", prevNew: nil, merged: false))
        // even when the LM kept the typed non-word
        XCTAssertEqual(Policy.boundary(o("isnstead", "isnstead", margin: 0.3, fixes: ["instead"]), mode: .auto,
                                       hasPrev: false, prevOut: nil, userWord: false), .apply(out: "instead", prevNew: nil, merged: false))
    }

    func testTrulyAmbiguousIsUnderlined() {
        let d = Policy.boundary(o("hwat", "what", margin: 0.2, fixes: ["what", "hat"], fixGap: 0.4), mode: .auto, hasPrev: false, prevOut: nil, userWord: false)
        XCTAssertEqual(d, .flag(fixes: ["what", "hat"], spelling: true))
    }

    func testProtectedWordsStay() {
        let base = { (t: String) in self.o(t, t, margin: 0.5, fixes: ["fix"]) }
        XCTAssertEqual(Policy.nonWord(o("brrr", "brrr", margin: 0, fixes: ["brr"]), nameLike: false), .notApplicable)   // stretched
        XCTAssertEqual(Policy.nonWord(o("iPhone", "iPhone", margin: 0, fixes: ["phone"]), nameLike: false), .notApplicable)   // mixed case
        XCTAssertEqual(Policy.nonWord(o("NASA", "NASA", margin: 0, fixes: ["NASAL"]), nameLike: false), .notApplicable)   // all caps
        XCTAssertEqual(Policy.nonWord(o("Mazinga", "Mazinga", margin: 0, fixes: ["Masinga"]), nameLike: true), .notApplicable)   // a name
        XCTAssertEqual(Policy.nonWord(o("lol", "lol", margin: 0, fixes: ["low"]), nameLike: false), .notApplicable)   // short
        XCTAssertEqual(Policy.nonWord(o("kubectl", "kubectl", margin: 0, fixes: ["kubelet"]), nameLike: false), .notApplicable)   // 2 edits
        XCTAssertEqual(Policy.nonWord(o("gonna", "gonna", margin: 0, fixes: ["gone"], oov: false), nameLike: false), .notApplicable)   // a word
        // personal dictionary / Not a typo
        XCTAssertEqual(Policy.boundary(base("hlep"), mode: .auto, hasPrev: false, prevOut: nil, userWord: true), .keep)
    }

    func testNameLike() {
        XCTAssertTrue(Policy.nameLike("Mazinga", left: "I talked to"))
        XCTAssertFalse(Policy.nameLike("Hlep", left: ""))
        XCTAssertFalse(Policy.nameLike("Hlep", left: "ok."))
        XCTAssertFalse(Policy.nameLike("hlep", left: "I need"))
    }
}
