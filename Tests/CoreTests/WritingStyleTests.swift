import Engine
import XCTest
@testable import KeylimeCore

/// The style picker's token and params, from a model entry shaped like the live manifest's m2s_int4 / block4.
final class WritingStyleTests: XCTestCase {
    static let pen: [String: Any] = ["split": 2, "space": 3, "contr": 1, "contr_rw": 0, "gdrop": 1, "merge": 4]
    static let penFormal: [String: Any] = ["split": 2, "space": 3, "contr": -6, "contr_rw": 2, "gdrop": 6, "merge": 4, "caps": -2, "punct": 3, "comma": 0]
    // m2s is pinned to m2's params for every style (web/update_params.py PIN)
    static let pinned: [String: Any] = ["lam": 1.25, "bias": 0, "margin": 0, "lam_r": 1.25, "pen": pen, "pen_formal": penFormal]
    static let m2s: [String: Any] = ["id": "m2s_int4", "supports_style": true, "style_tokens": ["casual": 249, "standard": 250, "formal": 251],
                                     "params": pinned, "style_params": ["casual": pinned, "standard": pinned, "formal": pinned]]

    private func resolve(_ m: [String: Any], _ style: String) -> (Int?, DecodeParams) {
        let sup = m["supports_style"] as? Bool ?? false
        let toks = (m["style_tokens"] as? [String: Int]) ?? [:]
        let sp = (m["style_params"] as? [String: [String: Any]] ?? [:]).mapValues(DecodeParams.from(json:))
        let st = WritingStyle.effective(style, supportsStyle: sup)
        return (WritingStyle.token(st, supportsStyle: sup, tokens: toks),
                WritingStyle.params(st, supportsStyle: sup, params: DecodeParams.from(json: m["params"] as! [String: Any]), styleParams: sp,
                                    penFormal: WritingStyle.penFormal(m)))
    }

    func testStyleTokensAndPinnedParams() {
        for (st, tok) in [("casual", 249), ("standard", 250), ("formal", 251)] {
            let (t, p) = resolve(Self.m2s, st)
            XCTAssertEqual(t, tok)
            XCTAssertEqual(p.lam, 1.25); XCTAssertEqual(p.bias, 0); XCTAssertEqual(p.lamRe, 1.25); XCTAssertEqual(p.margin, 0)
        }
        XCTAssertEqual(resolve(Self.m2s, "casual").1.pen, resolve(Self.m2s, "standard").1.pen)
        XCTAssertNil(resolve(Self.m2s, "standard").1.pen["caps"])
        let f = resolve(Self.m2s, "formal").1.pen
        XCTAssertEqual(f["caps"], -2); XCTAssertEqual(f["contr"], -6); XCTAssertEqual(f["punct"], 3); XCTAssertEqual(f["comma"], 0)
    }

    func testModelWithoutStyleTokensDecodesAsStandard() {
        let block4: [String: Any] = ["id": "block4", "supports_style": false, "style_tokens": [String: Int](),
                                     "params": ["lam": 1.0, "bias": 0, "margin": 0, "lam_r": 1.4, "pen": Self.pen, "pen_formal": Self.penFormal]]
        let (t, p) = resolve(block4, "formal")
        XCTAssertNil(t)
        XCTAssertEqual(p.lam, 1.0); XCTAssertEqual(p.lamRe, 1.4)
        XCTAssertNil(p.pen["caps"], "the hidden picker's saved formal choice must not apply")
        XCTAssertEqual(WritingStyle.effective("formal", supportsStyle: false), "standard")
    }

    func testStoredValues() {
        XCTAssertEqual(WritingStyle.stored(nil), "standard")
        XCTAssertEqual(WritingStyle.stored("bogus"), "standard")
        XCTAssertEqual(WritingStyle.stored("formal"), "formal")
        XCTAssertEqual(WritingStyle.all, ["casual", "standard", "formal"])
    }

    func testCasualKeepsLowercaseI() {
        let o = WordOutcome(typed: "i", out: "i", margin: 9, gap: 0, fixes: [], typedOOV: false)
        XCTAssertEqual(Policy.boundary(o, mode: .auto, hasPrev: false, prevOut: nil, userWord: false), .apply(out: "I", prevNew: nil, merged: false))
        XCTAssertEqual(Policy.boundary(o, mode: .auto, hasPrev: false, prevOut: nil, userWord: false, capI: false), .keep)
        let t = WordOutcome(typed: "teh", out: "the", margin: 6, gap: 6, fixes: ["the"], recheck: "i", typedOOV: true)
        XCTAssertEqual(Policy.boundary(t, mode: .auto, hasPrev: true, prevOut: "ok", userWord: false, capI: false),
                       .apply(out: "the", prevNew: "i", merged: false))
    }

    func testFormalCommaAndCapitalThroughPolicy() {
        // the previous word gains a comma, the word itself is kept: written (any margin, like a re-check)
        let c = WordOutcome(typed: "let", out: "let", margin: 1, gap: 0, fixes: [], recheck: "come,", typedOOV: false)
        XCTAssertEqual(Policy.boundary(c, mode: .auto, hasPrev: true, prevOut: "come", userWord: false),
                       .apply(out: "let", prevNew: "come,", merged: false))
        XCTAssertEqual(Policy.boundary(c, mode: .suggest, hasPrev: true, prevOut: "come", userWord: false), .keep)
        // a sentence-start capital from the formal pass survives the non-word fix path
        // (a plain non-word typo: 4+ letters, one slip from the fix)
        let f = WordOutcome(typed: "hlep", out: "Help", margin: 1, gap: 6, fixes: ["help"], typedOOV: true)
        XCTAssertEqual(Policy.boundary(f, mode: .auto, hasPrev: false, prevOut: nil, userWord: false), .apply(out: "Help", prevNew: nil, merged: false))
        let f2 = WordOutcome(typed: "hlep", out: "help", margin: 1, gap: 6, fixes: ["help"], typedOOV: true)
        XCTAssertEqual(Policy.boundary(f2, mode: .auto, hasPrev: false, prevOut: nil, userWord: false), .apply(out: "help", prevNew: nil, merged: false))
        // capitals alone need the confident margin
        let h = WordOutcome(typed: "hello", out: "Hello", margin: 1, gap: 0, fixes: [], typedOOV: false)
        XCTAssertEqual(Policy.boundary(h, mode: .auto, hasPrev: false, prevOut: nil, userWord: false), .keep)
        let h2 = WordOutcome(typed: "hello", out: "Hello", margin: 4, gap: 0, fixes: [], typedOOV: false)
        XCTAssertEqual(Policy.boundary(h2, mode: .auto, hasPrev: false, prevOut: nil, userWord: false), .apply(out: "Hello", prevNew: nil, merged: false))
    }
}
