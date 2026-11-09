import XCTest
@testable import KeylimeCore

final class QualityGuardTests: XCTestCase {
    func testSlips() {
        XCTAssertTrue(QualityGuard.looksLikeSlip("teh", of: "the"))      // swap
        XCTAssertTrue(QualityGuard.looksLikeSlip("helo", of: "hello"))   // deletion
        XCTAssertTrue(QualityGuard.looksLikeSlip("thw", of: "the"))      // substitution
        XCTAssertTrue(QualityGuard.looksLikeSlip("thee", of: "the"))     // insertion
        XCTAssertFalse(QualityGuard.looksLikeSlip("kubectl", of: "kubelet"))
        XCTAssertFalse(QualityGuard.looksLikeSlip("the", of: "the"))
        XCTAssertFalse(QualityGuard.mayLearn("teh", undoneFix: "the", outIsCommon: true))
        XCTAssertTrue(QualityGuard.mayLearn("Keylime", undoneFix: "keyline", outIsCommon: false))
    }

    func testAccidentalUndo() {
        XCTAssertTrue(QualityGuard.accidentalUndo(undoneAt: 10, now: 12, wordNow: "the", correction: "the"))
        XCTAssertFalse(QualityGuard.accidentalUndo(undoneAt: 10, now: 12, wordNow: "teh", correction: "the"))
        XCTAssertFalse(QualityGuard.accidentalUndo(undoneAt: 10, now: 20, wordNow: "the", correction: "the"))
    }
}
