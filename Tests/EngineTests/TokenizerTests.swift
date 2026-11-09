import XCTest
@testable import Engine

final class TokenizerTests: XCTestCase {
    private func check(_ tok: SPTokenizer, _ cases: String) {
        let c = Fixtures.json(cases) as! [String: Any]
        var n = 0
        var bad = 0
        for e in c["encode"] as! [[String: Any]] {
            let text = e["text"] as! String
            let ids = (e["ids"] as! [NSNumber]).map { $0.intValue }
            let got = tok.encode(text)
            if got != ids { bad += 1; if bad < 5 { XCTFail("encode \(text.prefix(60).debugDescription): \(got) != \(ids)") } }
            XCTAssertEqual(tok.decode(ids), e["decoded"] as! String, "decode(encode) \(text.prefix(60))")
            n += 1
        }
        for e in c["decode"] as! [[String: Any]] {
            let ids = (e["ids"] as! [NSNumber]).map { $0.intValue }
            XCTAssertEqual(tok.decode(ids), e["text"] as! String, "decode \(ids)")
            n += 1
        }
        XCTAssertEqual(bad, 0)
        print("\(cases): \(n) cases, \(bad) encode mismatches")
    }

    func testM1() { check(Fixtures.tokM1, "tok_m1.json") }
    func testM2() { check(Fixtures.tokM2, "tok_m2.json") }

    func testStyleBytePiecesNeverInText() {
        let tok = Fixtures.tokM2
        XCTAssertEqual((249...251).map { tok.pieces[$0] }, ["<0xF5>", "<0xF6>", "<0xF7>"])
        for s in ["hello there", "café 😀", "õö÷"] { XCTAssertFalse(tok.encode(s).contains { (249...251).contains($0) }) }
    }
}
