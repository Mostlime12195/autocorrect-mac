import XCTest
@testable import KeylimeCore

final class WordFinderTests: XCTestCase {
    func loc(_ word: String, _ text: String, caret: Int? = nil, base: Int = 0, typed: Int = 0, notBefore: Int? = nil) -> Int? {
        let ns = text as NSString
        return WordFinder.locate(word, text: ns, base: base, caret: caret ?? base + ns.length, typedSince: typed, notBefore: notBefore)
    }

    func testFindsTheWordBeforeTheCaret() {
        XCTAssertEqual(loc("hlep", "can you hlep"), 8)
        XCTAssertEqual(loc("hlep", "can you hlep "), 8)
        XCTAssertEqual(loc("hlep", "can you hlep me"), 8)
        XCTAssertNil(loc("hlep", "can you hle"))           // not there yet (Electron lag)
        XCTAssertNil(loc("hlep", "can you hleper"))        // whole words only
        XCTAssertEqual(loc("hlep", "x hlep y", base: 100), 102)   // absolute offsets
        // the closest occurrence before the caret
        XCTAssertEqual(loc("the", "the cat the "), 8)
    }

    func testTheCaretMovedOnWhileWaiting() {
        let text = "pls hda" + String(repeating: " and more words", count: 3)
        // 45 units typed after the word: out of the plain window, found once the keys typed since are counted
        XCTAssertNil(loc("hda", text))
        XCTAssertEqual(loc("hda", text, typed: 45), 4)
        // ... but never before the previous word end's word
        XCTAssertNil(loc("the", "the cat" + String(repeating: " x", count: 20), typed: 60, notBefore: 4))
        XCTAssertEqual(loc("cat", "the cat" + String(repeating: " x", count: 20), typed: 60, notBefore: 4), 4)
    }

    func testWaitThenSkip() {
        XCTAssertEqual(WordFinder.step(found: 3, waited: 0), .found(3))
        XCTAssertEqual(WordFinder.step(found: 3, waited: 9), .found(3))
        XCTAssertEqual(WordFinder.step(found: nil, waited: 0), .wait)
        XCTAssertEqual(WordFinder.step(found: nil, waited: 0.2), .wait)   // the old 200 ms limit: still waiting
        XCTAssertEqual(WordFinder.step(found: nil, waited: WordFinder.WAIT), .skip)
        XCTAssertEqual(WordFinder.step(found: nil, waited: 0, final: true), .skip)
    }

    func testShifted() {
        XCTAssertEqual(WordFinder.shifted(10, at: 12, oldLen: 3, newLen: 4), 10)   // edit after it
        XCTAssertEqual(WordFinder.shifted(10, at: 6, oldLen: 4, newLen: 5), 11)    // the word itself fixed
        XCTAssertEqual(WordFinder.shifted(10, at: 0, oldLen: 2, newLen: 1), 9)
        XCTAssertNil(WordFinder.shifted(10, at: 8, oldLen: 4, newLen: 4))
    }
}
