import XCTest
@testable import KeylimeCore

final class MarkTrackerTests: XCTestCase {
    func testMarksFollowEditsBeforeThem() {
        let t = MarkTracker()
        t.add(start: 4, word: "teh", fixes: ["the"], spelling: true)
        XCTAssertEqual(t.reconcile("see teh cat").count, 0)
        XCTAssertEqual(t.marks[0].start, 4)
        // "oh " typed at the start
        XCTAssertEqual(t.reconcile("oh see teh cat").count, 0)
        XCTAssertEqual(t.marks[0].start, 7)
    }

    func testMarkDropsWhenItsWordChanges() {
        let t = MarkTracker()
        let m = t.add(start: 4, word: "teh", fixes: ["the"], spelling: true)
        XCTAssertEqual(t.reconcile("see tehx cat"), [m.id])
        XCTAssertTrue(t.isEmpty)
    }

    func testWholeWordsOnly() {
        let t = MarkTracker()
        t.add(start: 0, word: "teh", fixes: ["the"], spelling: true)
        XCTAssertEqual(t.reconcile("tehran").count, 1)
    }

    func testWindowBaseAndUtf16() {
        let t = MarkTracker()
        // "é" and an emoji before the word: offsets are UTF-16
        let text = "café 👋 teh"
        let start = ("café 👋 " as NSString).length
        t.add(start: 100 + start, word: "teh", fixes: ["the"], spelling: true)
        XCTAssertEqual(t.reconcile(text, base: 100).count, 0)
        XCTAssertEqual(t.marks[0].start, 100 + start)
        XCTAssertEqual(t.reconcile(text, base: 300).count, 1)   // window moved past it
    }

    func testApplyEditShiftsAndDrops() {
        let t = MarkTracker()
        let a = t.add(start: 0, word: "teh", fixes: [], spelling: true)
        let b = t.add(start: 10, word: "wrold", fixes: [], spelling: true)
        t.applyEdit(at: 4, oldLen: 3, newLen: 5)
        XCTAssertEqual(t.mark(id: a.id)?.start, 0)
        XCTAssertEqual(t.mark(id: b.id)?.start, 12)
        t.applyEdit(at: 1, oldLen: 1, newLen: 1)
        XCTAssertNil(t.mark(id: a.id))
    }

    func testOverlapReplacesAndLookup() {
        let t = MarkTracker()
        t.add(start: 0, word: "teh", fixes: [], spelling: true)
        let b = t.add(start: 1, word: "eh", fixes: [], spelling: false)
        XCTAssertEqual(t.marks.map(\.id), [b.id])
        XCTAssertEqual(t.mark(at: 3)?.id, b.id)
        XCTAssertNil(t.mark(at: 5))
        t.removeAll(in: 0..<2)
        XCTAssertTrue(t.isEmpty)
    }
}

final class MarkGraceTests: XCTestCase {
    func testStaleTextDoesNotDropMarksRightAway() {
        let t = MarkTracker()
        let m = t.add(start: 4, word: "teh", fixes: ["the"], spelling: true)
        // the app re-renders and briefly reports empty text
        XCTAssertEqual(t.reconcile("", now: 10, grace: 0.8), [])
        XCTAssertTrue(t.isMissing(m.id))
        XCTAssertEqual(t.reconcile("see teh cat", now: 10.3, grace: 0.8), [])
        XCTAssertFalse(t.isMissing(m.id))
        XCTAssertEqual(t.marks.count, 1)
    }

    func testAnEditedWordGoesAfterTheGrace() {
        let t = MarkTracker()
        let m = t.add(start: 4, word: "teh", fixes: ["the"], spelling: true)
        XCTAssertEqual(t.reconcile("see the cat", now: 0, grace: 0.8), [])
        XCTAssertEqual(t.reconcile("see the cat", now: 0.5, grace: 0.8), [])
        XCTAssertEqual(t.reconcile("see the cat", now: 0.9, grace: 0.8), [m.id])
        XCTAssertTrue(t.isEmpty)
    }
}

final class MarkOriginTests: XCTestCase {
    func testPauseRecheckOnlyTakesBackItsOwnMarks() {
        let t = MarkTracker()
        let typed = t.add(start: 0, word: "hlep", fixes: ["help"], spelling: true)
        t.add(start: 10, word: "form", fixes: ["from"], spelling: false, fromIdle: true)
        t.removeAll(in: 0..<20, onlyIdle: true)
        XCTAssertEqual(t.marks.map(\.id), [typed.id])
        XCTAssertTrue(t.has(start: 0, word: "hlep"))
    }

    func testParkedMarksComeBack() {
        let t = MarkTracker()
        t.add(start: 0, word: "hlep", fixes: ["help"], spelling: true)
        let parked = t.marks
        t.removeAll()
        t.restore(parked)
        XCTAssertEqual(t.marks.count, 1)
        let n = t.add(start: 10, word: "teh", fixes: [], spelling: true)
        XCTAssertNotEqual(n.id, parked[0].id)
    }
}
