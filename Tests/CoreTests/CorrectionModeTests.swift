import XCTest
@testable import KeylimeCore

final class CorrectionModeTests: XCTestCase {
    func testSuggestOnlyIsTheDefault() {
        XCTAssertEqual(CorrectionMode.defaultMode, .suggest)
        XCTAssertEqual(CorrectionMode.stored(nil), .suggest)
        XCTAssertEqual(CorrectionMode.stored(""), .suggest)
        XCTAssertEqual(CorrectionMode.stored("bogus"), .suggest)
    }

    func testASavedChoiceIsKept() {
        XCTAssertEqual(CorrectionMode.stored("auto"), .auto)
        XCTAssertEqual(CorrectionMode.stored("suggest"), .suggest)
        XCTAssertEqual(CorrectionMode.stored("off"), .off)
    }
}
