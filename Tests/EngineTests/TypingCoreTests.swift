import XCTest
@testable import Engine

final class TypingCoreTests: XCTestCase {
    let p = DecodeParams(lam: 1.25, bias: 0, margin: 0, lamR: 1.25)
    let corr = Corrector(gen: Fixtures.gen, gen2: Fixtures.gen2)
    /// LM that likes "the" and "I"-words and nothing odd
    let lm = FakeLm { reqs in reqs.map { r in
        let w = r.cont.trimmingCharacters(in: .whitespaces)
        return ["the", "cat", "sat", "I", "i", "hello", "something", "some", "thing"].contains(w) || r.cont.hasSuffix(" the cat") ? -2.0 : -20.0
    } }

    /// type a string; returns the text the app would show (passes + injections applied)
    @discardableResult
    func type(_ core: TypingCore, _ s: String, _ shown: inout String, canCorrect: Bool = true, resolveWith: ((CorrectionJob) -> WordResult?)? = nil) -> [Injection] {
        var injections: [Injection] = []
        for c in s {
            let k: KeyInput = c == "\u{8}" ? .backspace : (c == "\u{1b}" ? .reset : .text(String(c)))
            switch core.key(k, canCorrect: canCorrect) {
            case .pass:
                if case .backspace = k { if !shown.isEmpty { shown.removeLast() } } else if case .text(let t) = k { shown += t }
            case .hold(let job):
                let r = resolveWith.map { $0(job) } ?? (try! corr.correctWord(job.input, scorer: lm, params: p, prev: job.prev, merge: job.merge))
                if let inj = core.resolve(job, r) {
                    shown = String(shown.dropLast(inj.deletes)) + inj.text
                    injections.append(inj)
                }
                shown += job.sep   // the held separator goes out after the edit
            case .undo(let inj, _):
                shown = String(shown.dropLast(inj.deletes)) + inj.text
                injections.append(inj)
            }
        }
        return injections
    }

    func testCorrectsAndUndoes() {
        let core = TypingCore()
        var shown = ""
        let inj = type(core, "teh ", &shown)
        XCTAssertEqual(shown, "the ")
        XCTAssertEqual(inj, [Injection(deletes: 2, text: "he")])
        XCTAssertEqual(core.context, "the ")
        // backspace right after: back to what was typed, and it stays at the next space
        if case .undo(let u, let learned) = core.key(.backspace, canCorrect: true) {
            XCTAssertEqual(u, Injection(deletes: 3, text: "eh"))
            XCTAssertEqual(learned, Undone(typed: "teh", out: "the"))
            shown = String(shown.dropLast(u.deletes)) + u.text
        } else { XCTFail("expected undo") }
        XCTAssertEqual(shown, "teh")
        XCTAssertEqual(core.word, "teh")
        type(core, " cat ", &shown)
        XCTAssertEqual(shown, "teh cat ")
    }

    func testNoUndoAfterOtherKeys() {
        let core = TypingCore()
        var shown = ""
        type(core, "teh c\u{8}\u{8}", &shown)
        XCTAssertEqual(shown, "the")
        XCTAssertEqual(core.context, "the")
    }

    func testResetAndOpeners() {
        let core = TypingCore()
        var shown = ""
        type(core, "@teh #teh teh\u{1b}", &shown)
        XCTAssertEqual(shown, "@teh #teh teh")
        XCTAssertEqual(core.context, "")
        type(core, "x/teh ", &shown, resolveWith: { _ in XCTFail("no correction after a slash"); return nil })
    }

    func testSkippedCorrectionKeepsTyping() {
        let core = TypingCore()
        var shown = ""
        type(core, "teh cat", &shown, resolveWith: { _ in nil })
        XCTAssertEqual(shown, "teh cat")
        XCTAssertEqual(core.context, "teh ")
        XCTAssertEqual(core.word, "cat")
    }

    func testCapitalI() {
        let core = TypingCore()
        var shown = ""
        type(core, "hello i sat", &shown)
        XCTAssertEqual(shown, "hello I sat")
        core.penalty = { a, b in a == "i" && b == "I" ? 3 : 0 }
        type(core, " i ", &shown)
        XCTAssertEqual(shown, "hello I sat i ")
    }

    func testNotCorrectingWhenDisabled() {
        let core = TypingCore()
        var shown = ""
        type(core, "teh ", &shown, canCorrect: false)
        XCTAssertEqual(shown, "teh ")
    }

    func testCorrectableWords() {
        XCTAssertTrue(TypingCore.correctable("don't"))
        XCTAssertTrue(TypingCore.correctable("dogs'"))
        XCTAssertFalse(TypingCore.correctable("'tis"))
        XCTAssertFalse(TypingCore.correctable("a''b"))
        XCTAssertFalse(TypingCore.correctable("abc1"))
        XCTAssertFalse(TypingCore.correctable("café"))
    }
}
