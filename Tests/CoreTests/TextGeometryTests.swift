import XCTest
@testable import KeylimeCore

final class TextGeometryTests: XCTestCase {
    /// monospace stand-in: 10 pt per UTF-16 unit
    let mono: (String) -> CGFloat = { CGFloat(($0 as NSString).length) * 10 }

    func testChildrenMapAcrossParagraphBreaks() {
        let field = "hello teh world\nsecond line"
        let kids = ["hello ", "teh", " world", "second line"]
        let starts = TextGeometry.childStarts(field: field, children: kids)
        XCTAssertEqual(starts, [0, 6, 9, 16])
        XCTAssertEqual(TextGeometry.childFor(start: 6, length: 3, starts: starts, children: kids)?.index, 1)
        XCTAssertEqual(TextGeometry.childFor(start: 23, length: 4, starts: starts, children: kids)?.local, 7)
        XCTAssertNil(TextGeometry.childFor(start: 4, length: 4, starts: starts, children: kids))   // spans two nodes
    }

    func testChildrenInOrderAndMissing() {
        let starts = TextGeometry.childStarts(field: "a b a b", children: ["a", "b", "zzz", "a", ""])
        XCTAssertEqual(starts, [0, 2, nil, 4, nil])
    }

    func testSpanIsProportional() {
        // node drawn 200 pt wide while the stand-in measures 100: everything scales by 2
        let r = TextGeometry.span(in: "see teh cat", local: 4, length: 3, frame: CGRect(x: 100, y: 50, width: 220, height: 20), width: mono)
        XCTAssertEqual(r, CGRect(x: 180, y: 50, width: 60, height: 20))
        XCTAssertNil(TextGeometry.span(in: "abc", local: 2, length: 3, frame: CGRect(x: 0, y: 0, width: 30, height: 10), width: mono))
    }

    func testBeforeCaret() {
        let caret = CGRect(x: 300, y: 40, width: 0, height: 22)
        // "teh " typed: the word starts 4 units before the caret
        XCTAssertEqual(TextGeometry.beforeCaret(caret: caret, between: "teh ", wordLength: 3, width: mono),
                       CGRect(x: 260, y: 40, width: 30, height: 22))
        XCTAssertNil(TextGeometry.beforeCaret(caret: caret, between: "teh\nx", wordLength: 3, width: mono))
    }
}
