import Engine
import Foundation

/// What Keylime does with what it finds.
public enum CorrectionMode: String, CaseIterable {
    /// confident fixes are applied, everything else flagged is underlined (default)
    case auto
    /// underline everything flagged, never change the text
    case suggest
    case off
}

/// A finished word's decision, reduced to what the policy needs (built from a WordResult on the engine queue).
public struct WordOutcome: Equatable {
    public let typed: String
    /// the corrector's choice for this word
    public let out: String
    /// chosen score minus the best other (first pass)
    public let margin: Double
    /// chosen score minus the typed word's score (infinity when the typed string isn't a candidate)
    public let gap: Double
    /// best fixes other than the typed word, at most 3
    public let fixes: [String]
    /// "some thing" -> "something": merge of the previous word and this one
    public let merge: String?
    /// the previous word's re-check: its new text
    public let recheck: String?
    /// typed isn't a lexicon word (a spelling fix, not a real-word swap)
    public let typedOOV: Bool
    /// score of the best fix minus the second best (infinity with one fix)
    public let fixGap: Double

    public init(typed: String, out: String, margin: Double, gap: Double, fixes: [String], merge: String? = nil,
                recheck: String? = nil, typedOOV: Bool, fixGap: Double = .infinity) {
        self.typed = typed; self.out = out; self.margin = margin; self.gap = gap; self.fixes = fixes; self.merge = merge
        self.recheck = recheck; self.typedOOV = typedOOV; self.fixGap = fixGap
    }

    public init(_ r: WordResult, typedOOV: Bool) {
        let ti = r.slot.typedIdx
        let gap = ti < 0 ? Double.infinity : r.scores[r.chosen] - r.scores[ti]
        let t = r.slot.typed
        // fixes (candidates other than the typed word), best first, with their scores
        var fx: [(String, Double)] = []
        for i in r.slot.cands.indices.sorted(by: { r.scores[$0] != r.scores[$1] ? r.scores[$0] > r.scores[$1] : $0 < $1 }) {
            let c = r.slot.cands[i]
            if c.lowercased() == t.lowercased() || fx.contains(where: { $0.0 == c }) { continue }
            fx.append((c, r.scores[i]))
            if fx.count == 3 { break }
        }
        self.init(typed: t, out: r.out, margin: r.margin, gap: gap, fixes: fx.map { $0.0 },
                  merge: r.merge?.to, recheck: r.recheck?.to, typedOOV: typedOOV,
                  fixGap: fx.count > 1 ? fx[0].1 - fx[1].1 : .infinity)
    }
}

public enum Policy {
    /// an automatic correction needs its choice to beat the runner-up by this much (Android CONFIDENT_MARGIN)
    public static let CONFIDENT_MARGIN = 3.0
    /// a word is flagged when its best fix beats it by this much (Android FLAG_MARGIN)
    public static let FLAG_MARGIN = 1.5
    /// the idle pass only changes text (auto mode, current sentence, spelling fixes) at this gap
    public static let IDLE_APPLY_GAP = 4.0
    /// a non-word whose two best fixes are both one edit away and closer than this is truly ambiguous: underlined
    public static let AMBIGUOUS_GAP = 1.0

    public enum NonWord: Equatable {
        /// fix it with this (the LM only chose between candidates)
        case fix(String)
        /// two fixes, both one edit away, about equally likely: underline
        case ambiguous
        /// not a plain non-word typo: the margin rule decides
        case notApplicable
    }

    /// "Should we correct" apart from "which fix": a typed non-word (not in the lexicon or the personal dictionary,
    /// plain lowercase or Capitalized, 4+ letters, not stretched like "sooo", not a name mid-sentence) with a fix one
    /// edit away (swaps included) gets fixed whatever the LM margin.
    public static func nonWord(_ o: WordOutcome, nameLike: Bool) -> NonWord {
        let t = o.typed
        guard o.typedOOV, !nameLike, t.count >= 4, plainCase(t), !stretched(t), let best = o.fixes.first, !best.contains(" "),
              QualityGuard.looksLikeSlip(t, of: best) else { return .notApplicable }
        if o.fixes.count > 1, !o.fixes[1].contains(" "), QualityGuard.looksLikeSlip(t, of: o.fixes[1]), o.fixGap < AMBIGUOUS_GAP {
            return .ambiguous
        }
        return .fix(best)
    }

    /// A change that would undo something deliberate-looking: re-casing a mixed-case / ALLCAPS non-word
    /// (iPhone -> iphone), or rewriting one beyond a slip; un-stretching "sooo" / "lllmo" (a slip fix like "asssault"
    /// -> "assault" is still fine).
    public static func isProtected(_ typed: String, out: String, typedOOV: Bool) -> Bool {
        // re-casing a mixed-case / ALLCAPS word is never a typo fix, word or not (iPhone -> iphone)
        if !plainCase(typed) && typed.lowercased() == out.lowercased() && typed != out { return true }
        guard typedOOV else { return false }
        let slip = QualityGuard.looksLikeSlip(typed, of: out)
        if !plainCase(typed) && (typed.lowercased() == out.lowercased() || !slip) { return true }
        if stretched(typed) && !slip { return true }
        return false
    }

    /// lowercase, or one capital at the start (not ALLCAPS, not iPhone / McDonald)
    public static func plainCase(_ w: String) -> Bool {
        let letters = w.filter { $0.isLetter }
        guard let f = letters.first else { return false }
        return letters.dropFirst().allSatisfy { $0.isLowercase } && (f.isLowercase || f.isUppercase)
    }

    /// a letter three times in a row: "sooo", "brrr", "lllmo" (deliberate)
    public static func stretched(_ w: String) -> Bool {
        let cs = Array(w.lowercased())
        guard cs.count >= 3 else { return false }
        for i in 2..<cs.count where cs[i] == cs[i - 1] && cs[i] == cs[i - 2] { return true }
        return false
    }

    /// a capitalised word that isn't at the start of a sentence: probably a name
    public static func nameLike(_ typed: String, left: String) -> Bool {
        guard let f = typed.first, f.isUppercase else { return false }
        guard let last = left.last(where: { !$0.isWhitespace }) else { return false }
        return !".!?\n:\"(".contains(last)
    }

    public enum Boundary: Equatable {
        case keep
        /// replace the word (and the previous word when prevNew / merged) with this
        case apply(out: String, prevNew: String?, merged: Bool)
        /// leave the text, underline the word
        case flag(fixes: [String], spelling: Bool)
    }

    /// Stage (b): a word just ended. hasPrev: the previous word is still right before it (re-check / merge possible).
    /// nameLike: capitalised mid-sentence (Policy.nameLike); forceNonWords: false = the old margin-only rule
    public static func boundary(_ o: WordOutcome, mode: CorrectionMode, hasPrev: Bool, prevOut: String?, userWord: Bool,
                                penalty: (String, String) -> Double = { _, _ in 0 }, nameLike: Bool = false,
                                forceNonWords: Bool = true) -> Boundary {
        if mode == .off || userWord { return .keep }
        let nw = forceNonWords ? nonWord(o, nameLike: nameLike) : .notApplicable
        let flag: Boundary = (o.out != o.typed && o.gap >= FLAG_MARGIN && !o.fixes.isEmpty) || nw != .notApplicable ?
            .flag(fixes: o.fixes, spelling: o.typedOOV || isSpellingEdit(o.typed, o.out, typedOOV: o.typedOOV)) : .keep
        if mode == .suggest { return flag }
        let mg = hasPrev ? o.merge : nil
        // a plain non-word typo: fixed with the best candidate, consistently (no margin); only truly ambiguous ones
        // are underlined
        if mg == nil {
            switch nw {
            case .fix(let best):
                let rc = hasPrev ? o.recheck.map { TypingCore.capIWords($0, penalty: penalty) } : nil
                return .apply(out: TypingCore.capIWords(best, penalty: penalty), prevNew: rc != nil && rc != prevOut ? rc : nil, merged: false)
            case .ambiguous:
                return flag
            case .notApplicable:
                break
            }
        }
        // unsure: mark, never edit (Android "only auto-correct when confident")
        if o.out != o.typed && mg == nil && o.margin < CONFIDENT_MARGIN { return flag }
        let rc = (mg == nil && hasPrev) ? o.recheck.map { TypingCore.capIWords($0, penalty: penalty) } : nil
        let prevNew = rc != nil && rc != prevOut ? rc : nil
        let out = TypingCore.capIWords(mg ?? o.out, penalty: penalty)
        if out == o.typed && prevNew == nil { return .keep }
        // odd-looking non-words (iPhone, NASA, sooo, a name mid-sentence) are never changed by themselves: underline
        if forceNonWords && out != o.typed && isProtected(o.typed, out: out, typedOOV: o.typedOOV) { return flag }
        return .apply(out: out, prevNew: prevNew, merged: mg != nil)
    }

    public enum Idle: Equatable { case none, apply, flag }

    /// Stage (c): a sentence fix found after a pause. inCurrentSentence: the sentence the caret is in, before the caret.
    public static func idle(gap: Double, spelling: Bool, mode: CorrectionMode, inCurrentSentence: Bool, userWord: Bool) -> Idle {
        if mode == .off || userWord || gap < FLAG_MARGIN { return .none }
        if mode == .auto && inCurrentSentence && spelling && gap >= IDLE_APPLY_GAP { return .apply }
        return .flag
    }

    /// a spelling fix (typed isn't a word): not a case / punctuation change, not a real-word swap
    public static func isSpellingEdit(_ typed: String, _ out: String, typedOOV: Bool) -> Bool {
        if typed.contains(" ") || out.contains(" ") { return false }
        let a = typed.lowercased(), b = out.lowercased()
        if a == b { return false }
        if a.filter({ $0.isLetter || $0.isNumber }) == b.filter({ $0.isLetter || $0.isNumber }) { return false }
        return typedOOV
    }
}
