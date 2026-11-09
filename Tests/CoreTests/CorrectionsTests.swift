import XCTest
@testable import KeylimeCore

final class CorrectionsTests: XCTestCase {
    static let allowedKeys: Set<String> = ["v", "id", "day", "type", "platform", "app_version", "model", "kind", "typed", "suggestion",
                                           "alternatives", "outcome", "picked_rank", "final", "margin", "before", "after"]

    func decision(_ outcome: String = "auto_applied_kept", typed: String = "teh", suggestion: String = "the",
                  alts: [String] = ["tea", "te1", "ten"], rank: Int? = nil, final: String? = nil, margin: Double? = 5,
                  before: String? = "I will see You", after: String? = " soon. Bye", model: String = "m2s_int4",
                  kind: String = "spelling") -> CorrectionDecision {
        CorrectionDecision(typed: typed, suggestion: suggestion, alternatives: alts, kind: kind, outcome: outcome, pickedRank: rank,
                           final: final, margin: margin, textBefore: before, textAfter: after, model: model, appVersion: "0.3.0")
    }

    func make(_ d: CorrectionDecision) -> [String: Any]? {
        CorrectionEvents.make(d, id: "abcdef0123456789", now: Date(timeIntervalSince1970: 0))
    }

    func alts(_ e: [String: Any]?) -> [String] {
        ((e?["alternatives"] as? [[String: Any]]) ?? []).map { "\($0["w"] as? String ?? "?")@\($0["rank"] as? Int ?? -1)" }
    }

    // MARK: scrubber

    func testTokens() {
        XCTAssertTrue(Scrub.tokenOk("don't"))
        XCTAssertTrue(Scrub.tokenOk("x.y"))
        XCTAssertTrue(Scrub.tokenOk("café"))
        XCTAssertFalse(Scrub.tokenOk(""))
        XCTAssertFalse(Scrub.tokenOk("..."))       // no letter
        XCTAssertFalse(Scrub.tokenOk("a/b"))
        XCTAssertFalse(Scrub.tokenOk("a b"))
        XCTAssertFalse(Scrub.tokenOk("abc1"))
        XCTAssertFalse(Scrub.tokenOk("me@x.com"))
        XCTAssertTrue(Scrub.tokenOk(String(repeating: "a", count: 20)))
        XCTAssertFalse(Scrub.tokenOk(String(repeating: "a", count: 21)))
        XCTAssertTrue(Scrub.wordOk("a lot", maxTokens: 2))
        XCTAssertFalse(Scrub.wordOk("a lot", maxTokens: 1))
        XCTAssertFalse(Scrub.wordOk("a  lot", maxTokens: 2))
        XCTAssertFalse(Scrub.wordOk(nil, maxTokens: 2))
    }

    func testContextTokens() {
        XCTAssertEqual(Scrub.contextToken("Hello,"), "hello")
        XCTAssertEqual(Scrub.contextToken("“Quote”"), "quote")
        XCTAssertEqual(Scrub.contextToken("(Don't)"), "don't")
        XCTAssertNil(Scrub.contextToken("123"))
        XCTAssertNil(Scrub.contextToken("5pm"))
        XCTAssertNil(Scrub.contextToken("me@x.com"))
        XCTAssertNil(Scrub.contextToken("https://x.y"))
        XCTAssertNil(Scrub.contextToken("<https://example.com/path>"))
        XCTAssertNil(Scrub.contextToken(String(repeating: "a", count: 21)))
        XCTAssertNil(Scrub.contextToken("--"))
    }

    func testContextWindow() {
        XCTAssertEqual(Scrub.before("we will see You"), ["see", "you"])
        // a dropped token isn't replaced by a word further away
        XCTAssertEqual(Scrub.before("send it to me@x.com please"), ["please"])
        XCTAssertEqual(Scrub.before("call 5551234 now"), ["now"])
        XCTAssertEqual(Scrub.before("first line\nsecond "), ["second"])
        XCTAssertEqual(Scrub.before("one two\r\nthree "), ["three"])
        XCTAssertEqual(Scrub.before("line\n"), [])
        XCTAssertEqual(Scrub.before(nil), [])
        XCTAssertEqual(Scrub.after(" soon. Bye"), ["soon"])
        XCTAssertEqual(Scrub.after(" https://example.com is"), [])
        XCTAssertEqual(Scrub.after("\nnext line"), [])
        XCTAssertEqual(Scrub.after(""), [])
    }

    func testPasswordFieldRecordsNothing() {
        XCTAssertTrue(CorrectionEvents.recordable(secureField: false, secureInput: false, excludedApp: false))
        XCTAssertFalse(CorrectionEvents.recordable(secureField: true, secureInput: false, excludedApp: false))
        XCTAssertFalse(CorrectionEvents.recordable(secureField: false, secureInput: true, excludedApp: false))
        XCTAssertFalse(CorrectionEvents.recordable(secureField: false, secureInput: false, excludedApp: true))
    }

    // MARK: events

    func testKeptEvent() throws {
        let e = try XCTUnwrap(make(decision()))
        XCTAssertEqual(e["v"] as? Int, 2)
        XCTAssertEqual(e["id"] as? String, "abcdef0123456789")
        XCTAssertEqual(e["day"] as? String, "1970-01-01")
        XCTAssertEqual(e["type"] as? String, "correction")
        XCTAssertEqual(e["platform"] as? String, "mac")
        XCTAssertEqual(e["app_version"] as? String, "0.3.0")
        XCTAssertEqual(e["model"] as? String, "m2s_int4")
        XCTAssertEqual(e["kind"] as? String, "spelling")
        XCTAssertEqual(e["typed"] as? String, "teh")
        XCTAssertEqual(e["suggestion"] as? String, "the")
        XCTAssertEqual(e["outcome"] as? String, "auto_applied_kept")
        XCTAssertEqual(e["margin"] as? String, "4-8")
        XCTAssertEqual(e["before"] as? [String], ["see", "you"])
        XCTAssertEqual(e["after"] as? [String], ["soon"])
        XCTAssertNil(e["picked_rank"])
        XCTAssertNil(e["final"])
        XCTAssertEqual(Set(e.keys), Self.allowedKeys.subtracting(["picked_rank", "final"]))
    }

    func testRanksKeepTheirPlaceWhenAnAlternativeIsScrubbed() {
        // "te1" (rank 2) is dropped, "ten" keeps rank 3
        XCTAssertEqual(alts(make(decision())), ["tea@1", "ten@3"])
        // at most 3 alternatives, none equal to the suggestion or each other
        XCTAssertEqual(alts(make(decision(alts: ["the", "tea", "tea", "ten"]))), ["tea@2"])
        XCTAssertNil(make(decision(alts: []))?["alternatives"])
    }

    func testPickedRank() {
        XCTAssertNil(make(decision("suggestion_picked")))                         // no rank
        XCTAssertEqual(make(decision("suggestion_picked", rank: 0))?["picked_rank"] as? Int, 0)
        XCTAssertEqual(make(decision("suggestion_picked", rank: 3))?["picked_rank"] as? Int, 3)
        XCTAssertNil(make(decision("suggestion_picked", rank: 2)))                // that alternative was scrubbed
        XCTAssertNil(make(decision("suggestion_picked", rank: 7)))
        // picked_rank only on picks
        XCTAssertNil(make(decision("suggestion_ignored", rank: 1))?["picked_rank"])
    }

    func testManualFix() {
        XCTAssertEqual(make(decision("manual_fix", final: "then"))?["final"] as? String, "then")
        XCTAssertEqual(make(decision("manual_fix", final: "a lot"))?["final"] as? String, "a lot")
        XCTAssertNil(make(decision("manual_fix")))
        XCTAssertNil(make(decision("manual_fix", final: "teh")))
        XCTAssertNil(make(decision("manual_fix", final: "the")))
        XCTAssertNil(make(decision("manual_fix", final: "th3n")))
        XCTAssertNil(make(decision("auto_applied_undone", final: "then"))?["final"])
    }

    func testDroppedEvents() {
        XCTAssertNil(make(decision(typed: "te h")))
        XCTAssertNil(make(decision(typed: "abc123")))
        XCTAssertNil(make(decision(typed: "me@x.com")))
        XCTAssertNil(make(decision(suggestion: "teh")))
        XCTAssertNil(make(decision(suggestion: "a lot of")))
        XCTAssertNil(make(decision("missed")))
        XCTAssertNil(make(decision("whatever")))
        XCTAssertNil(make(decision(kind: "other")))
        XCTAssertNil(make(decision(model: "bad model")))
        XCTAssertEqual(make(decision(suggestion: "a lot"))?["suggestion"] as? String, "a lot")
        XCTAssertEqual(make(decision(model: "M2S_INT4"))?["model"] as? String, "m2s_int4")
    }

    func testNoExtraKeys() throws {
        let ds = [decision(), decision("suggestion_picked", rank: 1), decision("manual_fix", final: "then"),
                  decision("not_a_typo", margin: nil, before: nil, after: nil), decision("auto_applied_undone", alts: [])]
        for d in ds {
            let e = try XCTUnwrap(make(d))
            XCTAssertTrue(Set(e.keys).isSubset(of: Self.allowedKeys), "\(e.keys)")
            let line = try XCTUnwrap(CorrectionEvents.line(e))
            XCTAssertFalse(line.contains("\n"))
            let back = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            XCTAssertEqual(Set(back.keys), Set(e.keys))
        }
        let e = try XCTUnwrap(make(decision("not_a_typo", margin: nil, before: nil, after: nil)))
        XCTAssertNil(e["margin"]); XCTAssertNil(e["before"]); XCTAssertNil(e["after"])
    }

    func testKindsAndMargins() {
        XCTAssertEqual(Kinds.classify(typed: "dont", fix: "don't", typedInVocab: false), "punctuation")
        XCTAssertEqual(Kinds.classify(typed: "cafe", fix: "café", typedInVocab: true), "punctuation")
        XCTAssertEqual(Kinds.classify(typed: "form", fix: "from", typedInVocab: true), "real_word")
        XCTAssertEqual(Kinds.classify(typed: "teh", fix: "the", typedInVocab: false), "spelling")
        XCTAssertEqual(Kinds.classify(typed: "there", fix: "their", rewind: true, typedInVocab: true), "grammar")
        XCTAssertEqual(Kinds.marginBucket(0.5), "0-1")
        XCTAssertEqual(Kinds.marginBucket(1), "1-2")
        XCTAssertEqual(Kinds.marginBucket(3), "2-4")
        XCTAssertEqual(Kinds.marginBucket(7.9), "4-8")
        XCTAssertEqual(Kinds.marginBucket(.infinity), "8+")
        XCTAssertEqual(Kinds.marginBucket(.nan), "0-1")
    }

    // MARK: upload

    func testClassify() {
        XCTAssertEqual(UploadCore.classify(200), .advance)
        XCTAssertEqual(UploadCore.classify(204), .advance)
        XCTAssertEqual(UploadCore.classify(413), .split)
        XCTAssertEqual(UploadCore.classify(408), .retry)
        XCTAssertEqual(UploadCore.classify(429), .retry)
        XCTAssertEqual(UploadCore.classify(503), .retry)
        XCTAssertEqual(UploadCore.classify(-1), .retry)
        XCTAssertEqual(UploadCore.classify(400), .skip)
        XCTAssertEqual(UploadCore.classify(410), .skip)
        XCTAssertEqual(UploadCore.classify(422), .skip)
    }

    func testDrainHalvesOn413() {
        let lines = (0..<10).map { "{\"n\":\($0)}" }
        var sizes: [Int] = []
        let d = UploadCore.drain(lines, maxEvents: 8) { chunk in
            sizes.append(chunk.count)
            return (chunk.count > 3 ? 413 : 200, nil)
        }
        XCTAssertEqual(sizes, [8, 4, 2, 2, 2, 2, 2])
        XCTAssertEqual(d, UploadCore.Drained(consumed: 10, sent: 10, skipped: 0, retryCode: nil, retryAfter: nil))
    }

    func testDrainSkipsASingleEventThatIsTooLarge() {
        let d = UploadCore.drain(["a", "b"], maxEvents: 4) { _ in (413, nil) }
        XCTAssertEqual(d.consumed, 2)
        XCTAssertEqual(d.skipped, 2)
        XCTAssertEqual(d.sent, 0)
    }

    func testDrainStopsOnRetryAndSkipsRejected() {
        var calls = 0
        let d = UploadCore.drain(["1", "2", "3", "4", "5"], maxEvents: 2) { _ in
            calls += 1
            if calls == 1 { return (code: 200, retryAfter: nil) }
            return (code: 503, retryAfter: 30)
        }
        XCTAssertEqual(d, UploadCore.Drained(consumed: 2, sent: 2, skipped: 0, retryCode: 503, retryAfter: 30))
        let r = UploadCore.drain(["1", "2", "3"], maxEvents: 2) { _ in (400, nil) }
        XCTAssertEqual(r, UploadCore.Drained(consumed: 3, sent: 0, skipped: 3, retryCode: nil, retryAfter: nil))
    }

    func testDrainByteLimit() {
        var sizes: [Int] = []
        _ = UploadCore.drain(Array(repeating: String(repeating: "x", count: 10), count: 5), maxEvents: 500, maxBytes: 25) { c in
            sizes.append(c.count)
            return (200, nil)
        }
        XCTAssertEqual(sizes, [2, 2, 1])
    }

    func testEnvelopeAndDeleteURL() throws {
        let e = try XCTUnwrap(make(decision()))
        let line = try XCTUnwrap(CorrectionEvents.line(e))
        let data = try XCTUnwrap(UploadCore.envelope(installId: "id-1", appVersion: "0.3.0", lines: [line, line]))
        let doc = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(doc.keys), ["schema", "install_id", "app_version", "events"])
        XCTAssertEqual(doc["schema"] as? String, "autocorrect-events/2")
        XCTAssertEqual((doc["events"] as? [Any])?.count, 2)
        XCTAssertEqual(UploadCore.deleteURL("https://h.example/api/v1/upload", installId: "abc"), "https://h.example/api/v1/install/abc")
        XCTAssertEqual(UploadCore.deleteURL("https://h.example/api/v1/upload/", installId: "abc"), "https://h.example/api/v1/install/abc")
    }
}
