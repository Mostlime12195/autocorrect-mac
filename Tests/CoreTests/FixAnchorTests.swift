import XCTest
@testable import KeylimeCore

final class FixAnchorTests: XCTestCase {
    func testAppliesToAFinishedWord() {
        XCTAssertEqual(FixAnchor.check(text: "see teh ", caret: 8, old: "teh", start: 4), .apply(at: 4))
    }

    func testNeverTheWordStillBeingTyped() {
        // a fix for "teh" with the caret right after it and no separator: it's still being typed
        XCTAssertEqual(FixAnchor.check(text: "see teh", caret: 7, old: "teh", start: 4), .wait("it's the word at the caret"))
        // caret inside it
        XCTAssertEqual(FixAnchor.check(text: "see teh", caret: 5, old: "teh", start: 4), .wait("it's the word at the caret"))
    }

    func testFixArrivingMidWordWaits() {
        // "teh " then the user started the next word: wait for its separator or a pause
        XCTAssertEqual(FixAnchor.check(text: "see teh ca", caret: 10, old: "teh", start: 4), .wait("the user is mid-word"))
        // after the next separator it goes through
        XCTAssertEqual(FixAnchor.check(text: "see teh cat ", caret: 12, old: "teh", start: 4), .apply(at: 4))
        // or after a pause, even with the caret in the next word
        XCTAssertEqual(FixAnchor.check(text: "see teh ca", caret: 10, old: "teh", start: 4, typing: false), .apply(at: 4))
        // but never the word at the caret itself, pause or not
        XCTAssertEqual(FixAnchor.check(text: "see teh", caret: 7, old: "teh", start: 4, typing: false), .wait("it's the word at the caret"))
    }

    func testTargetEditedBeforeApplyIsDropped() {
        XCTAssertEqual(FixAnchor.check(text: "see the ", caret: 8, old: "teh", start: 4), .drop("the text changed"))
        XCTAssertEqual(FixAnchor.check(text: "see tehx ", caret: 9, old: "teh", start: 4), .drop("the text changed"))
    }

    func testTargetThatMovedIsFoundByContent() {
        // text typed before it since the fix was decided
        XCTAssertEqual(FixAnchor.check(text: "oh, see teh ", caret: 12, old: "teh", start: 4), .apply(at: 8))
    }

    func testExplicitActionsMayTouchTheCaretWord() {
        XCTAssertEqual(FixAnchor.check(text: "see teh", caret: 5, old: "teh", start: 4, atCaretOK: true), .apply(at: 4))
    }

    /// Keys typed while a fix is written are held, then replayed at the restored caret: nothing lost, reordered or
    /// typed into the selection.
    func testKeysHeldDuringAWriteLandAfterIt() {
        var text = "see teh ca" as NSString
        var caret = NSRange(location: 10, length: 0)
        let held = "t "   // typed while the fix was being written
        // the write: select "teh", replace with "the", caret restored relative to the text
        let r = NSRange(location: 4, length: 3)
        guard case .apply = FixAnchor.check(text: text as String, caret: 10, old: "teh", start: 4, atCaretOK: false) else {
            // mid-word: the fix waits; the keys go out first, then the fix lands at the next separator
            text = text.replacingCharacters(in: caret, with: held) as NSString
            caret.location += (held as NSString).length
            XCTAssertEqual(FixAnchor.check(text: text as String, caret: caret.location, old: "teh", start: 4), .apply(at: 4))
            text = text.replacingCharacters(in: r, with: "the") as NSString
            caret = FixAnchor.caretAfter(sel: caret, replaced: r, newLength: 3)
            XCTAssertEqual(text, "see the cat ")
            XCTAssertEqual(caret.location, 12)
            return
        }
        XCTFail("a fix must not be written while the user is mid-word")
    }

    func testCaretRestoreWhenTheLengthChanges() {
        // "alot" -> "a lot" before the caret: the caret moves with its text
        XCTAssertEqual(FixAnchor.caretAfter(sel: NSRange(location: 9, length: 0), replaced: NSRange(location: 4, length: 4), newLength: 5),
                       NSRange(location: 10, length: 0))
        // caret before the target: unchanged
        XCTAssertEqual(FixAnchor.caretAfter(sel: NSRange(location: 2, length: 0), replaced: NSRange(location: 4, length: 4), newLength: 5),
                       NSRange(location: 2, length: 0))
    }
}
