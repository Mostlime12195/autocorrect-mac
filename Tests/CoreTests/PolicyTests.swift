import XCTest
@testable import KeylimeCore
import Engine

final class PolicyTests: XCTestCase {
    func o(_ typed: String, _ out: String, margin: Double, gap: Double, fixes: [String]? = nil, merge: String? = nil,
           recheck: String? = nil, oov: Bool = true) -> WordOutcome {
        WordOutcome(typed: typed, out: out, margin: margin, gap: gap, fixes: fixes ?? (out == typed ? [] : [out]), merge: merge,
                    recheck: recheck, typedOOV: oov)
    }

    func testConfidentFixApplies() {
        XCTAssertEqual(Policy.boundary(o("teh", "the", margin: 6, gap: 6), mode: .auto, hasPrev: false, prevOut: nil, userWord: false),
                       .apply(out: "the", prevNew: nil, merged: false))
    }

    func testUnsureFixIsUnderlinedInAutoMode() {
        XCTAssertEqual(Policy.boundary(o("form", "from", margin: 1, gap: 2, oov: false), mode: .auto, hasPrev: false, prevOut: nil, userWord: false),
                       .flag(fixes: ["from"], spelling: false))
    }

    func testWeakFixIsNeitherAppliedNorFlagged() {
        XCTAssertEqual(Policy.boundary(o("abc", "abd", margin: 0.5, gap: 1), mode: .auto, hasPrev: false, prevOut: nil, userWord: false), .keep)
    }

    func testSuggestModeOnlyEditsFixedWords() {
        XCTAssertEqual(Policy.boundary(o("teh", "the", margin: 9, gap: 9), mode: .suggest, hasPrev: false, prevOut: nil, userWord: false),
                       .flag(fixes: ["the"], spelling: true))
        // i -> I and the missing-apostrophe table are the exception: always the same, whatever the mode
        XCTAssertEqual(Policy.boundary(o("i", "i", margin: 9, gap: 0), mode: .suggest, hasPrev: false, prevOut: nil, userWord: false),
                       .apply(out: "I", prevNew: nil, merged: false))
        XCTAssertEqual(Policy.boundary(o("dont", "done", margin: 1, gap: 2), mode: .suggest, hasPrev: false, prevOut: nil, userWord: false),
                       .apply(out: "don't", prevNew: nil, merged: false))
        // no re-check of the previous word in suggest mode
        XCTAssertEqual(Policy.boundary(o("im", "im", margin: 1, gap: 0, recheck: "so"), mode: .suggest, hasPrev: true, prevOut: "si",
                                       userWord: false), .apply(out: "I'm", prevNew: nil, merged: false))
    }

    func testOffAndUserWords() {
        XCTAssertEqual(Policy.boundary(o("teh", "the", margin: 9, gap: 9), mode: .off, hasPrev: false, prevOut: nil, userWord: false), .keep)
        XCTAssertEqual(Policy.boundary(o("teh", "the", margin: 9, gap: 9), mode: .auto, hasPrev: false, prevOut: nil, userWord: true), .keep)
    }

    func testCapitalI() {
        XCTAssertEqual(Policy.boundary(o("i", "i", margin: 9, gap: 0), mode: .auto, hasPrev: false, prevOut: nil, userWord: false),
                       .apply(out: "I", prevNew: nil, merged: false))
        XCTAssertEqual(Policy.boundary(o("i", "i", margin: 9, gap: 0), mode: .auto, hasPrev: false, prevOut: nil, userWord: false,
                                       penalty: { _, _ in 3 }), .keep)
    }

    func testRecheckAndMergeNeedThePreviousWord() {
        let r = o("cat", "cat", margin: 9, gap: 0, recheck: "the")
        XCTAssertEqual(Policy.boundary(r, mode: .auto, hasPrev: true, prevOut: "teh", userWord: false), .apply(out: "cat", prevNew: "the", merged: false))
        XCTAssertEqual(Policy.boundary(r, mode: .auto, hasPrev: false, prevOut: nil, userWord: false), .keep)
        let m = o("thing", "thing", margin: 0.2, gap: 0, merge: "something")
        XCTAssertEqual(Policy.boundary(m, mode: .auto, hasPrev: true, prevOut: "some", userWord: false), .apply(out: "something", prevNew: nil, merged: true))
    }

    func testIdle() {
        XCTAssertEqual(Policy.idle(gap: 5, spelling: true, mode: .auto, inCurrentSentence: true, userWord: false), .apply)
        XCTAssertEqual(Policy.idle(gap: 5, spelling: true, mode: .auto, inCurrentSentence: false, userWord: false), .flag)
        XCTAssertEqual(Policy.idle(gap: 5, spelling: false, mode: .auto, inCurrentSentence: true, userWord: false), .flag)
        XCTAssertEqual(Policy.idle(gap: 3, spelling: true, mode: .auto, inCurrentSentence: true, userWord: false), .flag)
        XCTAssertEqual(Policy.idle(gap: 9, spelling: true, mode: .suggest, inCurrentSentence: true, userWord: false), .flag)
        XCTAssertEqual(Policy.idle(gap: 1, spelling: true, mode: .suggest, inCurrentSentence: true, userWord: false), .none)
        XCTAssertEqual(Policy.idle(gap: 9, spelling: true, mode: .off, inCurrentSentence: true, userWord: false), .none)
    }

    func testSpellingEdit() {
        XCTAssertTrue(Policy.isSpellingEdit("teh", "the", typedOOV: true))
        XCTAssertFalse(Policy.isSpellingEdit("form", "from", typedOOV: false))
        XCTAssertFalse(Policy.isSpellingEdit("dont", "don't", typedOOV: true))
        XCTAssertFalse(Policy.isSpellingEdit("alot", "a lot", typedOOV: true))
    }
}

final class NonWordPolicyTests: XCTestCase {
    func o(_ typed: String, _ out: String, margin: Double, fixes: [String], fixGap: Double = 5, oov: Bool = true) -> WordOutcome {
        WordOutcome(typed: typed, out: out, margin: margin, gap: 1.5, fixes: fixes, typedOOV: oov, fixGap: fixGap)
    }

    func testNonWordIsFixedWhateverTheMargin() {
        // the diag case: "underlined, 3 fixes (margin 0.1, gap 1.5)"
        XCTAssertEqual(Policy.boundary(o("hlep", "help", margin: 0.1, fixes: ["help", "held", "heap"], fixGap: 2), mode: .auto,
                                       hasPrev: false, prevOut: nil, userWord: false), .apply(out: "help", prevNew: nil, merged: false))
        // even when the LM kept the typed non-word
        XCTAssertEqual(Policy.boundary(o("isnstead", "isnstead", margin: 0.3, fixes: ["instead"]), mode: .auto,
                                       hasPrev: false, prevOut: nil, userWord: false), .apply(out: "instead", prevNew: nil, merged: false))
    }

    func testAmbiguousIsFixedInAutoAndUnderlinedInSuggest() {
        let w = o("hwat", "what", margin: 0.2, fixes: ["what", "hat"], fixGap: 0.4)
        XCTAssertEqual(Policy.nonWord(w, nameLike: false), .ambiguous("what"))
        XCTAssertEqual(Policy.boundary(w, mode: .auto, hasPrev: false, prevOut: nil, userWord: false), .apply(out: "what", prevNew: nil, merged: false))
        XCTAssertEqual(Policy.boundary(w, mode: .suggest, hasPrev: false, prevOut: nil, userWord: false), .flag(fixes: ["what", "hat"], spelling: true))
        // the "underliner" report: whichever of the two is ahead in this context, it's applied (not underlined once,
        // fixed the next time)
        for (fixes, gap) in [(["underline", "underlines"], 0.3), (["underlines", "underline"], 0.2), (["underline", "underlines"], 2.0)] {
            let u = o("underliner", fixes[0], margin: 0.1, fixes: fixes, fixGap: gap)
            XCTAssertEqual(Policy.boundary(u, mode: .auto, hasPrev: false, prevOut: nil, userWord: false),
                           .apply(out: fixes[0], prevNew: nil, merged: false))
        }
    }

    func testUndoneFixSticks() {
        // the user undid underliner -> underline: neither that nor the runner-up is applied again, an underline at most
        let undone: (String, String) -> Double = { a, b in a == "underliner" && b == "underline" ? 3 : 0 }
        for (fixes, gap) in [(["underline", "underlines"], 5.0), (["underlines", "underline"], 0.3), (["underline", "underlines"], 0.3)] {
            let u = o("underliner", fixes[0], margin: 4, fixes: fixes, fixGap: gap)
            XCTAssertEqual(Policy.boundary(u, mode: .auto, hasPrev: false, prevOut: nil, userWord: false, penalty: undone),
                           .flag(fixes: fixes, spelling: true))
        }
        // other words are still fixed
        XCTAssertEqual(Policy.boundary(o("hlep", "help", margin: 0.1, fixes: ["help"]), mode: .auto, hasPrev: false, prevOut: nil,
                                       userWord: false, penalty: undone), .apply(out: "help", prevNew: nil, merged: false))
        // the margin path too: a confident real-word swap the user undid
        let fr = WordOutcome(typed: "form", out: "from", margin: 6, gap: 6, fixes: ["from"], typedOOV: false)
        XCTAssertEqual(Policy.boundary(fr, mode: .auto, hasPrev: false, prevOut: nil, userWord: false),
                       .apply(out: "from", prevNew: nil, merged: false))
        XCTAssertEqual(Policy.boundary(fr, mode: .auto, hasPrev: false, prevOut: nil, userWord: false, penalty: { _, _ in 3 }),
                       .flag(fixes: ["from"], spelling: false))
    }

    func testProtectedWordsStay() {
        let base = { (t: String) in self.o(t, t, margin: 0.5, fixes: ["fix"]) }
        XCTAssertEqual(Policy.nonWord(o("brrr", "brrr", margin: 0, fixes: ["brr"]), nameLike: false), .notApplicable)   // stretched
        XCTAssertEqual(Policy.nonWord(o("iPhone", "iPhone", margin: 0, fixes: ["phone"]), nameLike: false), .notApplicable)   // mixed case
        XCTAssertEqual(Policy.nonWord(o("NASA", "NASA", margin: 0, fixes: ["NASAL"]), nameLike: false), .notApplicable)   // all caps
        XCTAssertEqual(Policy.nonWord(o("Mazinga", "Mazinga", margin: 0, fixes: ["Masinga"]), nameLike: true), .notApplicable)   // a name
        XCTAssertEqual(Policy.nonWord(o("lol", "lol", margin: 0, fixes: ["low"]), nameLike: false), .notApplicable)   // short
        XCTAssertEqual(Policy.nonWord(o("kubectl", "kubectl", margin: 0, fixes: ["kubelet"]), nameLike: false), .notApplicable)   // 2 edits
        XCTAssertEqual(Policy.nonWord(o("gonna", "gonna", margin: 0, fixes: ["gone"], oov: false), nameLike: false), .notApplicable)   // a word
        // personal dictionary / Not a typo
        XCTAssertEqual(Policy.boundary(base("hlep"), mode: .auto, hasPrev: false, prevOut: nil, userWord: true), .keep)
    }

    func testProtectedWordsAreNotChangedEvenWhenConfident() {
        let iphone = WordOutcome(typed: "iPhone", out: "iphone", margin: 5.6, gap: 5.6, fixes: ["iphone"], typedOOV: true)
        XCTAssertEqual(Policy.boundary(iphone, mode: .auto, hasPrev: false, prevOut: nil, userWord: false), .keep)
        XCTAssertEqual(Policy.boundary(iphone, mode: .suggest, hasPrev: false, prevOut: nil, userWord: false), .keep)
        let stretched = WordOutcome(typed: "lllmo", out: "lmao", margin: 5.7, gap: 5.7, fixes: ["lmao"], typedOOV: true)
        XCTAssertEqual(Policy.boundary(stretched, mode: .auto, hasPrev: false, prevOut: nil, userWord: false), .flag(fixes: ["lmao"], spelling: true))
        // even when the lowercase form is a lexicon word
        let known = WordOutcome(typed: "iPhone", out: "iphone", margin: 5.6, gap: 5.6, fixes: ["iphone"], typedOOV: false)
        XCTAssertEqual(Policy.boundary(known, mode: .auto, hasPrev: false, prevOut: nil, userWord: false), .keep)
        // a slip with a tripled letter is still a typo
        let assault = WordOutcome(typed: "asssault", out: "assault", margin: 6, gap: 6, fixes: ["assault"], typedOOV: true)
        XCTAssertEqual(Policy.boundary(assault, mode: .auto, hasPrev: false, prevOut: nil, userWord: false), .apply(out: "assault", prevNew: nil, merged: false))
        // a capitalised typo mid-sentence keeps the margin rule
        let nexr = WordOutcome(typed: "Nexr", out: "Next", margin: 6, gap: 6, fixes: ["Next"], typedOOV: true)
        XCTAssertEqual(Policy.boundary(nexr, mode: .auto, hasPrev: false, prevOut: nil, userWord: false, nameLike: true), .apply(out: "Next", prevNew: nil, merged: false))
        // a plain confident fix still goes through
        let teh = WordOutcome(typed: "teh", out: "the", margin: 6, gap: 6, fixes: ["the"], typedOOV: true)
        XCTAssertEqual(Policy.boundary(teh, mode: .auto, hasPrev: false, prevOut: nil, userWord: false), .apply(out: "the", prevNew: nil, merged: false))
    }

    func testNameLike() {
        XCTAssertTrue(Policy.nameLike("Mazinga", left: "I talked to"))
        XCTAssertFalse(Policy.nameLike("Hlep", left: ""))
        XCTAssertFalse(Policy.nameLike("Hlep", left: "ok."))
        XCTAssertFalse(Policy.nameLike("hlep", left: "I need"))
    }
}

final class FixedWordsPolicyTests: XCTestCase {
    func w(_ typed: String, _ out: String, margin: Double = 0.5, fixes: [String] = [], oov: Bool = true) -> WordOutcome {
        WordOutcome(typed: typed, out: out, margin: margin, gap: 0, fixes: fixes, typedOOV: oov)
    }

    func testLoneIAndItsContractions() {
        for (t, want) in [("i", "I"), ("i'm", "I'm"), ("i'll", "I'll"), ("i'd", "I'd"), ("i've", "I've"), ("im", "I'm"), ("ive", "I've"),
                          ("Im", "I'm"), ("i\u{2019}m", "I\u{2019}m")] {
            for mode in [CorrectionMode.auto, .suggest] {
                XCTAssertEqual(Policy.boundary(w(t, t), mode: mode, hasPrev: false, prevOut: nil, userWord: false),
                               .apply(out: want, prevNew: nil, merged: false), "\(t) \(mode)")
            }
        }
        // formal: the corrector already capitalised it, at a low margin (was an underline before)
        XCTAssertEqual(Policy.boundary(w("i", "I", margin: 0.3, oov: false), mode: .auto, hasPrev: false, prevOut: nil, userWord: false),
                       .apply(out: "I", prevNew: nil, merged: false))
        // already right, off, casual, undone, personal dictionary: nothing
        XCTAssertEqual(Policy.boundary(w("I", "I"), mode: .suggest, hasPrev: false, prevOut: nil, userWord: false), .keep)
        XCTAssertEqual(Policy.boundary(w("i", "i"), mode: .off, hasPrev: false, prevOut: nil, userWord: false), .keep)
        XCTAssertEqual(Policy.boundary(w("i", "i"), mode: .suggest, hasPrev: false, prevOut: nil, userWord: false, capI: false), .keep)
        XCTAssertEqual(Policy.boundary(w("im", "im"), mode: .auto, hasPrev: false, prevOut: nil, userWord: false, capI: false), .keep)
        XCTAssertEqual(Policy.boundary(w("i", "i"), mode: .suggest, hasPrev: false, prevOut: nil, userWord: false,
                                       penalty: { a, b in a == "i" && b == "I" ? 3 : 0 }), .keep)
        XCTAssertEqual(Policy.boundary(w("im", "im"), mode: .auto, hasPrev: false, prevOut: nil, userWord: true), .keep)
        // a name mid-sentence (Jony Ive) isn't an I-word
        XCTAssertEqual(Policy.boundary(w("Ive", "Ive"), mode: .suggest, hasPrev: false, prevOut: nil, userWord: false, nameLike: true), .keep)
    }

    func testMissingApostrophes() {
        for (t, want) in [("dont", "don't"), ("Dont", "Don't"), ("doesnt", "doesn't"), ("youre", "you're"), ("thats", "that's"),
                          ("wouldve", "would've"), ("aint", "ain't")] {
            XCTAssertEqual(Policy.boundary(w(t, t), mode: .suggest, hasPrev: false, prevOut: nil, userWord: false),
                           .apply(out: want, prevNew: nil, merged: false), t)
            // whatever the corrector picked, and in auto mode at any margin
            XCTAssertEqual(Policy.boundary(w(t, "done", margin: 9, fixes: ["done"]), mode: .auto, hasPrev: false, prevOut: nil, userWord: false),
                           .apply(out: want, prevNew: nil, merged: false), t)
        }
        // the formal style's sentence-start capital is kept
        XCTAssertEqual(Policy.boundary(w("dont", "Don't"), mode: .auto, hasPrev: false, prevOut: nil, userWord: false),
                       .apply(out: "Don't", prevNew: nil, merged: false))
        // real words are not in the table: the usual rules decide
        for t in ["wont", "cant", "its", "lets", "id", "ill", "hell", "shell", "well", "were"] {
            XCTAssertNil(FixedWords.fix(t), t)
            XCTAssertEqual(Policy.boundary(w(t, t, oov: false), mode: .suggest, hasPrev: false, prevOut: nil, userWord: false), .keep, t)
        }
        // undone: left as typed (not fixed to something else either)
        XCTAssertEqual(Policy.boundary(w("dont", "done", margin: 9, fixes: ["done", "don't"]), mode: .auto, hasPrev: false, prevOut: nil,
                                       userWord: false, penalty: { a, b in a == "dont" && b == "don't" ? 3 : 0 }), .keep)
        // a merge with the previous word goes first
        let m = WordOutcome(typed: "dont", out: "dont", margin: 0.2, gap: 0, fixes: [], merge: "x", typedOOV: true)
        XCTAssertEqual(Policy.boundary(m, mode: .auto, hasPrev: true, prevOut: "y", userWord: false), .apply(out: "x", prevNew: nil, merged: true))
    }

    func testRecheckOfThePreviousWordInAutoMode() {
        let r = WordOutcome(typed: "dont", out: "dont", margin: 0.2, gap: 0, fixes: [], recheck: "the", typedOOV: true)
        XCTAssertEqual(Policy.boundary(r, mode: .auto, hasPrev: true, prevOut: "teh", userWord: false),
                       .apply(out: "don't", prevNew: "the", merged: false))
    }

    func testTable() {
        XCTAssertEqual(FixedWords.fix("DONT"), nil)   // ALLCAPS: left alone
        XCTAssertEqual(FixedWords.fix("dOnt"), nil)
        XCTAssertEqual(FixedWords.fix("don't"), nil)
        XCTAssertEqual(FixedWords.fix("Ive"), "I've")
        XCTAssertEqual(FixedWords.fix("Thats"), "That's")
        XCTAssertEqual(FixedWords.fix("hello"), nil)
        // every entry: lowercase, the fixed form is the typed one plus an apostrophe
        XCTAssertGreaterThan(FixedWords.table.count, 30)
        for (t, f) in FixedWords.table {
            XCTAssertEqual(t, t.lowercased())
            XCTAssertEqual(f.replacingOccurrences(of: "'", with: ""), t)
            XCTAssertEqual(f.filter { $0 == "'" }.count, 1)
        }
        for t in ["wont", "cant", "its", "lets", "id", "ill", "hell", "shell", "well", "were", "youd"] { XCTAssertNil(FixedWords.table[t], t) }
    }
}
