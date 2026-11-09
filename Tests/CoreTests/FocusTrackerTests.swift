import XCTest
@testable import KeylimeCore

/// Electron's focus query flaps between the field and "no value": the field (and its underlines) must survive that.
final class FocusTrackerTests: XCTestCase {
    /// the host's reaction, as TextLayer does it: marks go only when the field really changes or is lost
    final class Host {
        let focus = FocusTracker<Int>(grace: 3, same: ==)
        let marks = MarkTracker()
        var path = "unknown"
        var drops = 0
        func probe(_ found: Int?, _ t: Double, _ alive: Liveness) {
            switch focus.observe(found, now: t, alive: { _ in alive }) {
            case .same, .holding: path = "ax"
            case .changed: marks.removeAll(); path = "ax"
            case .lost, .none: marks.removeAll(); path = "keys"; drops += 1
            }
        }
    }

    func testFlappingFocusKeepsThePathAndTheMarks() {
        let h = Host()
        h.probe(7, 0, .answers)
        h.marks.add(start: 4, word: "teh", fixes: ["the"], spelling: true)
        var t = 0.0
        for i in 0..<200 {   // 80 s of polls, every other one failing, sometimes several in a row
            t += 0.4
            let fail = i % 2 == 0 || i % 7 == 0
            h.probe(fail ? nil : 7, t, .answers)
            XCTAssertEqual(h.path, "ax", "poll \(i)")
        }
        XCTAssertEqual(h.marks.marks.count, 1)
        XCTAssertEqual(h.drops, 0)
        XCTAssertGreaterThan(h.focus.failures, 100)
    }

    func testFocusedElementIsKeptThroughLongFailures() {
        let h = Host()
        h.probe(7, 0, .focused)
        h.marks.add(start: 0, word: "teh", fixes: [], spelling: true)
        for i in 1...50 { h.probe(nil, Double(i), .focused) }
        XCTAssertEqual(h.path, "ax")
        XCTAssertEqual(h.marks.marks.count, 1)
    }

    func testSustainedFailureOrDeadElementDemotes() {
        let h = Host()
        h.probe(7, 0, .answers)
        h.probe(nil, 1, .answers)
        h.probe(nil, 2.5, .answers)
        XCTAssertEqual(h.path, "ax")
        h.probe(nil, 4.1, .answers)   // > 3 s since the first failure in a row, focus never confirmed
        XCTAssertEqual(h.path, "keys")

        let d = Host()
        d.probe(7, 0, .answers)
        d.probe(nil, 0.1, .dead)
        XCTAssertEqual(d.path, "keys")
    }

    func testRealFocusChangeClearsMarks() {
        let h = Host()
        h.probe(7, 0, .answers)
        h.marks.add(start: 0, word: "teh", fixes: [], spelling: true)
        h.probe(7, 0.5, .answers)
        XCTAssertEqual(h.marks.marks.count, 1)
        h.probe(8, 1, .answers)
        XCTAssertTrue(h.marks.isEmpty)
    }
}
