import XCTest
@testable import KeylimeCore

final class UpdateCoreTests: XCTestCase {
    let good = #"{"version": "0.2.0", "url": "https://github.com/x/y/releases/download/mac-v0.2.0/Keylime-mac-0.2.0.zip", "sha256": "352b7a51838cc48db4dfd2e1b2004d517576aad66f1382372b3355130956bbe3", "size": 13449235, "notes": "hi"}"#

    func testParse() throws {
        let l = try UpdateCore.parse(Data(good.utf8))
        XCTAssertEqual(l.version, "0.2.0")
        XCTAssertEqual(l.size, 13449235)
        XCTAssertEqual(l.notes, "hi")
    }

    func testRejectsBadManifests() {
        for bad in [good.replacingOccurrences(of: "https://", with: "http://"),
                    good.replacingOccurrences(of: "\"0.2.0\"", with: "\"0.2.x\""),
                    good.replacingOccurrences(of: "352b7a", with: "352b7"),
                    good.replacingOccurrences(of: "13449235", with: "0"),
                    "{}", "nope"] {
            XCTAssertThrowsError(try UpdateCore.parse(Data(bad.utf8)), bad)
        }
    }

    func testVersionOrder() {
        XCTAssertTrue(UpdateCore.newer("0.2.0", than: "0.1.1"))
        XCTAssertTrue(UpdateCore.newer("0.10.0", than: "0.9.9"))
        XCTAssertTrue(UpdateCore.newer("1.0", than: "0.99.99"))
        XCTAssertFalse(UpdateCore.newer("0.2.0", than: "0.2.0"))
        XCTAssertFalse(UpdateCore.newer("0.2", than: "0.2.0"))
        XCTAssertFalse(UpdateCore.newer("0.1.9", than: "0.2.0"))
        XCTAssertFalse(UpdateCore.newer("garbage", than: "0.0.1"))
    }

    func testVerify() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("kl-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: f)
        defer { try? FileManager.default.removeItem(at: f) }
        let sha = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        XCTAssertEqual(try UpdateCore.sha256Hex(of: f), sha)
        func info(_ sha: String, _ size: Int) -> LatestInfo {
            try! UpdateCore.parse(Data(#"{"version":"1.0.0","url":"https://a.b/c.zip","sha256":"\#(sha)","size":\#(size)}"#.utf8))
        }
        XCTAssertNoThrow(try UpdateCore.verify(f, info(sha, 3)))
        XCTAssertThrowsError(try UpdateCore.verify(f, info(sha, 4)))
        XCTAssertThrowsError(try UpdateCore.verify(f, info(String(repeating: "0", count: 64), 3)))
    }
}
