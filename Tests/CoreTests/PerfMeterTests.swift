import XCTest
@testable import KeylimeCore

final class PerfMeterTests: XCTestCase {
    func testStatsOverTheLastMinute() {
        let m = PerfMeter()
        for i in 0..<20 { m.record(.wordEnd, ms: Double(10 + i), at: 100 + Double(i)) }
        m.record(.pass, ms: 900, at: 50)   // older than a minute by the end
        m.record(.pass, ms: 120, at: 130)
        m.cancelled(at: 131)
        let s = m.summary(now: 125 + 30, pauseSecs: 1, backlog: 0)
        XCTAssertEqual(s.wordEnds.count, 20)
        XCTAssertEqual(s.wordEnds.avgMs, 19.5, accuracy: 0.01)
        XCTAssertEqual(s.wordEnds.p95Ms, 28)   // nearest rank: the 19th of 20
        XCTAssertEqual(s.passes.count, 1)
        XCTAssertEqual(s.passes.avgMs, 120)
        XCTAssertEqual(s.cancelled, 1)
        XCTAssertNil(s.behind)
    }

    func testCpuPercentAndEnergy() {
        let m = PerfMeter()
        m.cpuSample(seconds: 10, at: 0)
        m.cpuSample(seconds: 13, at: 30)
        m.cpuSample(seconds: 16, at: 60)
        let s = m.summary(now: 60, pauseSecs: 1, backlog: 0)
        XCTAssertEqual(s.cpuPercent ?? -1, 10, accuracy: 0.01)
        XCTAssertEqual(s.energy, "moderate: noticeable on battery")
    }

    func testFallingBehind() {
        let m = PerfMeter()
        for i in 0..<3 { m.record(.pass, ms: 400, at: Double(i)) }
        XCTAssertNotNil(m.summary(now: 5, pauseSecs: 0.3, backlog: 0).behind)
        XCTAssertNil(m.summary(now: 5, pauseSecs: 1, backlog: 0).behind)
        XCTAssertNotNil(m.summary(now: 5, pauseSecs: 1, backlog: 4).behind)
    }
}
