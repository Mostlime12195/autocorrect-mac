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

    public init(typed: String, out: String, margin: Double, gap: Double, fixes: [String], merge: String? = nil,
                recheck: String? = nil, typedOOV: Bool) {
        self.typed = typed; self.out = out; self.margin = margin; self.gap = gap; self.fixes = fixes; self.merge = merge
        self.recheck = recheck; self.typedOOV = typedOOV
    }

    public init(_ r: WordResult, typedOOV: Bool) {
        let ti = r.slot.typedIdx
        let gap = ti < 0 ? Double.infinity : r.scores[r.chosen] - r.scores[ti]
        let t = r.slot.typed
        self.init(typed: t, out: r.out, margin: r.margin, gap: gap,
                  fixes: Array(r.ranked(5).filter { $0.lowercased() != t.lowercased() }.prefix(3)),
                  merge: r.merge?.to, recheck: r.recheck?.to, typedOOV: typedOOV)
    }
}

public enum Policy {
    /// an automatic correction needs its choice to beat the runner-up by this much (Android CONFIDENT_MARGIN)
    public static let CONFIDENT_MARGIN = 3.0
    /// a word is flagged when its best fix beats it by this much (Android FLAG_MARGIN)
    public static let FLAG_MARGIN = 1.5
    /// the idle pass only changes text (auto mode, current sentence, spelling fixes) at this gap
    public static let IDLE_APPLY_GAP = 4.0

    public enum Boundary: Equatable {
        case keep
        /// replace the word (and the previous word when prevNew / merged) with this
        case apply(out: String, prevNew: String?, merged: Bool)
        /// leave the text, underline the word
        case flag(fixes: [String], spelling: Bool)
    }

    /// Stage (b): a word just ended. hasPrev: the previous word is still right before it (re-check / merge possible).
    public static func boundary(_ o: WordOutcome, mode: CorrectionMode, hasPrev: Bool, prevOut: String?, userWord: Bool,
                                penalty: (String, String) -> Double = { _, _ in 0 }) -> Boundary {
        if mode == .off || userWord { return .keep }
        let flag: Boundary = (o.out != o.typed && o.gap >= FLAG_MARGIN && !o.fixes.isEmpty) ?
            .flag(fixes: o.fixes, spelling: isSpellingEdit(o.typed, o.out, typedOOV: o.typedOOV)) : .keep
        if mode == .suggest { return flag }
        let mg = hasPrev ? o.merge : nil
        // unsure: mark, never edit (Android "only auto-correct when confident")
        if o.out != o.typed && mg == nil && o.margin < CONFIDENT_MARGIN { return flag }
        let rc = (mg == nil && hasPrev) ? o.recheck.map { TypingCore.capIWords($0, penalty: penalty) } : nil
        let prevNew = rc != nil && rc != prevOut ? rc : nil
        let out = TypingCore.capIWords(mg ?? o.out, penalty: penalty)
        if out == o.typed && prevNew == nil { return .keep }
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
