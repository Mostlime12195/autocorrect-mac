import XCTest
@testable import Engine

/// The formal style's word pass (Corrector.kt formal: capitals, a comma after the previous word) and its pause pass
/// (Rewind: commas and sentence ends), with a stub LM.
final class StyleTests: XCTestCase {
    /// m2s's pinned params with the formal kind penalties (manifest params.pen_formal)
    let formalP = DecodeParams(lam: 1.25, bias: 0, margin: 0, lamR: 1.25,
                               pen: ["split": 2, "space": 3, "contr": -6, "contr_rw": 2, "gdrop": 6, "merge": 4, "caps": -2, "punct": 3, "comma": 0])
    let corr = Corrector(gen: Fixtures.gen, gen2: Fixtures.gen2)

    func testFormalCapitalisesSentenceStart() throws {
        let lm = FakeLm { reqs in reqs.map { $0.cont == "Hello" ? -1.0 : ($0.cont == "hello" ? -2.0 : -12.0) } }
        let r = try corr.correctWord(WordInput(typed: "hello", left: "", sep: ""), scorer: lm, params: formalP, prev: nil, formal: true)
        XCTAssertFalse(r.skipped, "the formal style always runs the LM")
        XCTAssertEqual(r.out, "Hello")
        // other styles: as typed
        let s = try corr.correctWord(WordInput(typed: "hello", left: "", sep: ""), scorer: lm, params: formalP, prev: nil)
        XCTAssertEqual(s.out, "hello")
        // mid-sentence: no capital
        let m = try corr.correctWord(WordInput(typed: "hello", left: "she said", sep: " "), scorer: lm, params: formalP, prev: nil, formal: true)
        XCTAssertEqual(m.out, "hello")
        // autoCap off: no sentence-start capital
        let n = try corr.correctWord(WordInput(typed: "hello", left: "", sep: ""), scorer: lm, params: formalP, prev: nil, formal: true, autoCap: false)
        XCTAssertEqual(n.out, "hello")
    }

    func testFormalCapitalI() throws {
        let lm = FakeLm { reqs in reqs.map { $0.cont == " I" ? -1.0 : ($0.cont == " i" ? -3.0 : -12.0) } }
        let r = try corr.correctWord(WordInput(typed: "i", left: "well", sep: " "), scorer: lm, params: formalP, prev: nil, formal: true)
        XCTAssertEqual(r.out, "I")
    }

    func testFormalCommaAfterPreviousWord() throws {
        let ps = corr.candidates("come", nil)
        let prev = PrevWord(slot: ps, idx: ps.typedIdx, left: "if you want to", sep: " ", lmScored: true)
        let lm = FakeLm { reqs in reqs.map { r in
            if r.cont == " come, let" { return -1.0 }
            if r.cont == " come let" { return -10.0 }
            if r.cont == " let" { return -2.0 }
            return -30.0
        } }
        let w = WordInput(typed: "let", left: "if you want to come", sep: " ")
        let r = try corr.correctWord(w, scorer: lm, params: formalP, prev: prev, formal: true)
        XCTAssertEqual(r.out, "let")
        XCTAssertEqual(r.prevText, "come,")
        XCTAssertNil(r.recheck)
        // not formal: no punctuation
        XCTAssertNil(try corr.correctWord(w, scorer: lm, params: formalP, prev: prev).prevText)
        // an undone comma needs SUPPRESS_NATS more
        let u = UserData(dict: nil, learn: nil)
        u.suppress("come", "come,")
        let c2 = Corrector(gen: Fixtures.gen, gen2: Fixtures.gen2, user: u)
        let weak = FakeLm { reqs in reqs.map { r in r.cont == " come, let" ? -1.0 : (r.cont == " come let" ? -3.0 : (r.cont == " let" ? -2.0 : -30.0)) } }
        XCTAssertNil(try c2.correctWord(w, scorer: weak, params: formalP, prev: prev, formal: true).prevText)
    }

    func testTypingCoreWritesTheComma() {
        let core = TypingCore()
        let lm = FakeLm { reqs in reqs.map { r in
            if r.cont.hasSuffix("come, let") { return -1.0 }
            if r.cont.hasSuffix("come let") { return -10.0 }
            return ["if", "If", "you", "want", "to", "come", "let"].contains(r.cont.trimmingCharacters(in: .whitespaces)) ? -2.0 : -30.0
        } }
        var shown = ""
        for c in "if you want to come let " {
            switch core.key(.text(String(c)), canCorrect: true) {
            case .pass: shown.append(c)
            case .hold(let job):
                let r = try! corr.correctWord(job.input, scorer: lm, params: formalP, prev: job.prev, merge: job.merge, formal: true)
                if let inj = core.resolve(job, r) { shown = String(shown.dropLast(inj.deletes)) + inj.text }
                shown += job.sep
            case .undo: XCTFail("no undo here")
            }
        }
        XCTAssertEqual(shown, "If you want to come, let ")
    }

    func testCommaKeepsTheShownCapital() {
        XCTAssertEqual(TypingCore.keepCase("if,", of: "If"), "If,")
        XCTAssertEqual(TypingCore.keepCase("their", of: "there"), "their")
        XCTAssertEqual(TypingCore.keepCase("come,", of: "come"), "come,")
        XCTAssertEqual(TypingCore.keepCase("come,", of: nil), "come,")
    }

    func testPunctTargets() {
        let t = Rewind.targets("we went home and then we slept")
        // a comma after every word but the last, a sentence end where 3+ words follow
        XCTAssertEqual(t.filter { $0.kind == .comma }.map { $0.word }, ["we", "went", "home", "and", "then", "we"])
        XCTAssertEqual(t.filter { $0.kind == .stop }.map { $0.word }, ["we went", "went home", "home and", "and then"])
        let stop = t.first { $0.kind == .stop && $0.word == "home and" }!
        XCTAssertEqual(stop.left, "we went"); XCTAssertEqual(stop.sep, " "); XCTAssertEqual(stop.right, " then we slept")
        XCTAssertEqual(stop.wordsBack, 4); XCTAssertEqual(stop.start, 8)
        // only the current line; already punctuated gaps are skipped; tried spots too
        let l = Rewind.targets("old line here\nyes, we went home", tried: { _, w in w == "went" })
        XCTAssertEqual(l.map { $0.word }, ["we"])
        XCTAssertTrue(Rewind.targets("hello").isEmpty)
    }

    func testPunctCheck() throws {
        let targets = Rewind.targets("we went home and then we slept")
        let lm = FakeLm { reqs in reqs.map { $0.cont.contains("home. And then") ? -1.0 : -7.0 } }
        let ch = try Rewind.check(targets, scorer: lm, lam: 1.25, pen: formalP.pen)
        // 1.25 * 6 - 3 (the formal punct penalty) = 4.5 < 6 + 0.5 (4 words back): not sure enough
        XCTAssertEqual(ch, [])
        let strong = FakeLm { reqs in reqs.map { $0.cont.contains("home. And then") ? -1.0 : -12.0 } }
        let ch2 = try Rewind.check(targets, scorer: strong, lam: 1.25, pen: formalP.pen)
        XCTAssertEqual(ch2.map { $0.to }, ["home. And"])
        XCTAssertEqual(ch2.first?.from, "home and")
        XCTAssertEqual(ch2.first?.start, 8)
        // autoCap off: no capital after the full stop
        let nc = try Rewind.check(Rewind.targets("we went home and then we slept", autoCap: false),
                                  scorer: FakeLm { reqs in reqs.map { $0.cont.contains("home. and then") ? -1.0 : -12.0 } }, lam: 1.25, pen: formalP.pen)
        XCTAssertEqual(nc.map { $0.to }, ["home. and"])
        // learned "not here"
        let u = UserData(dict: nil, learn: nil)
        u.suppress("home and", "home. And")
        let lm3 = FakeLm { reqs in reqs.map { $0.cont.contains("home. And then") ? -1.0 : -9.0 } }
        XCTAssertEqual(try Rewind.check(targets, scorer: lm3, lam: 1.25, pen: formalP.pen).count, 1)
        XCTAssertEqual(try Rewind.check(targets, scorer: lm3, lam: 1.25, user: u, pen: formalP.pen).count, 0)
        // commas
        let cm = try Rewind.check(targets, scorer: FakeLm { reqs in reqs.map { $0.cont.contains("home, and") ? -1.0 : -12.0 } }, lam: 1.25)
        XCTAssertEqual(cm.map { $0.to }, ["home,"])
    }

    func testOverlappingChangesKeepTheBest() {
        let a = PunctChange(start: 8, from: "home and", to: "home. And", margin: 9, wordsBack: 4)
        let b = PunctChange(start: 8, from: "home", to: "home,", margin: 7, wordsBack: 4)
        let c = PunctChange(start: 0, from: "we", to: "we,", margin: 6.5, wordsBack: 6)
        XCTAssertEqual(Rewind.nonOverlapping([b, a, c]), [a, c])
    }
}
