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
