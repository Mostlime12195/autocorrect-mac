import Foundation

/// A punctuation spot some way back, scored on everything typed after it (port of Corrector.kt RewindTarget, the formal
/// style's kinds). start: Character offset of `word` in the text the targets were built from.
///   comma: insert "," after `word`
///   stop:  end the sentence after it: `word` spans "word<sep>next", replaced by "word.<sep>Next" (capital with autoCap)
public struct PunctTarget: Equatable {
    public enum Kind: Equatable { case comma, stop }
    public let start: Int
    public let word: String
    public let left: String
    public let sep: String
    public let right: String
    public let wordsBack: Int
    public let kind: Kind
    public let autoCap: Bool
    public init(start: Int, word: String, left: String, sep: String, right: String, wordsBack: Int, kind: Kind, autoCap: Bool = true) {
        self.start = start; self.word = word; self.left = left; self.sep = sep; self.right = right; self.wordsBack = wordsBack
        self.kind = kind; self.autoCap = autoCap
    }
}

public struct PunctChange: Equatable {
    public let start: Int
    public let from: String
    public let to: String
    public let margin: Double
    public let wordsBack: Int
}

/// The formal style's punctuation after a pause (port of Rewind.punct + KeyboardController.idleRewind's formal targets):
/// commas and sentence ends, each scored on the whole remainder of the line with and without it. Only when the model is
/// very sure; the margin grows with distance.
public enum Rewind {
    /// LM log-prob margin (x lam_r) the change must win by. Conservative by default.
    public static let MARGIN = 6.0
    public static let MAX_WORDS_BACK = 3
    /// extra margin per word beyond MAX_WORDS_BACK (far changes need clearer evidence)
    public static let PER_WORD = 0.5
    public static let MAX_SENTENCE_WORDS = 20

    public static func marginFor(_ base: Double, _ wordsBack: Int) -> Double { base + PER_WORD * Double(max(0, wordsBack - MAX_WORDS_BACK)) }

    /// Targets in `text` (the line before the caret, ending after a finished word): a comma after every word followed by a
    /// single space, and a sentence end there when at least 3 words follow. `tried(start, word)`: already proposed, skip.
    public static func targets(_ text: String, autoCap: Bool = true, tried: (Int, String) -> Bool = { _, _ in false }) -> [PunctTarget] {
        let cs = Array(text)
        let cut = (cs.lastIndex(of: "\n") ?? -1) + 1
        let words = Array(segRanges(text).filter { $0.0 >= cut }.suffix(MAX_SENTENCE_WORDS))
        let n = words.count
        guard n >= 2 else { return [] }
        var out: [PunctTarget] = []
        for j in 0..<(n - 1) {
            let (a, b) = words[j]
            let w = String(cs[a..<b])
            if tried(a, w) { continue }
            let gap = String(cs[b..<words[j + 1].0])
            if gap != " " { continue }   // already punctuated (or a newline)
            let back = n - 1 - j
            let (left, sep) = TypingCore.splitLeft(String(cs[0..<a]))
            let next = String(cs[words[j + 1].0..<words[j + 1].1])
            let rest = trimEnd(String(cs[words[j + 1].1...]))
            out.append(PunctTarget(start: a, word: w, left: left, sep: sep, right: gap + next + rest, wordsBack: back, kind: .comma))
            // a sentence end only with at least 3 words of right context
            if n - 1 - (j + 1) >= 2 {
                out.append(PunctTarget(start: a, word: w + gap + next, left: left, sep: sep, right: rest, wordsBack: back, kind: .stop, autoCap: autoCap))
            }
        }
        return out
    }

    public static func check(_ targets: [PunctTarget], scorer: LmScorer, lam: Double, margin: Double = MARGIN, user: UserData? = nil,
                             pen: [String: Double] = [:], cancelled: () -> Bool = { false }) throws -> [PunctChange] {
        var out: [PunctChange] = []
        for t in targets {
            if cancelled() { break }
            if let c = try punct(t, scorer: scorer, lam: lam, margin: margin, user: user, pen: pen) { out.append(c) }
        }
        return out
    }

    /// one change per region: overlapping ones (a full stop over a comma) keep the best margin
    public static func nonOverlapping(_ changes: [PunctChange]) -> [PunctChange] {
        var keep: [PunctChange] = []
        for c in changes.sorted(by: { $0.margin > $1.margin }) {
            let cl = c.from.count
            if !keep.contains(where: { k in c.start < k.start + k.from.count && k.start < c.start + cl }) { keep.append(c) }
        }
        return keep
    }

    /// comma / sentence end after t.word, scored on the whole remainder (t.right) with and without it
    static func punct(_ t: PunctTarget, scorer: LmScorer, lam: Double, margin: Double, user: UserData?, pen: [String: Double]) throws -> PunctChange? {
        let to: String
        switch t.kind {
        case .comma:
            to = t.word + ","
        case .stop:
            // "word<sep>next" -> "word.<sep>Next" (just "word" without a next word: "word.")
            let cs = Array(t.word)
            if let i = cs.firstIndex(where: { $0.isWhitespace }), let j = cs[i...].firstIndex(where: { !$0.isWhitespace }) {
                let next = String(cs[j...])
                to = String(cs[0..<i]) + "." + String(cs[i..<j]) + (t.autoCap ? next.prefix(1).uppercased() + next.dropFirst() : next)
            } else {
                to = t.word + "."
            }
        }
        let lp = try scorer.score([LmReq(t.left, t.sep + t.word + t.right), LmReq(t.left, t.sep + to + t.right)])
        let kindPen = pen[t.kind == .comma ? "comma" : "punct"] ?? 0
        let m = lam * (lp[1] - lp[0]) - kindPen
        let need = marginFor(margin, t.wordsBack) + (user?.penalty(t.word, to) ?? 0)
        return m >= need ? PunctChange(start: t.start, from: t.word, to: to, margin: m, wordsBack: t.wordsBack) : nil
    }

    static func trimEnd(_ s: String) -> String {
        var cs = Substring(s)
        while let l = cs.last, l.isWhitespace { cs = cs.dropLast() }
        return String(cs)
    }
}
