import Foundation

/// A likely typo found by the sentence pass: Character offset `start` in the sentence, best fixes first.
public struct SentenceFix: Equatable {
    public let start: Int
    public let from: String
    public let to: String
    public let gap: Double
    public let fixes: [String]
    public init(start: Int, from: String, to: String, gap: Double, fixes: [String]) {
        self.start = start; self.from = from; self.to = to; self.gap = gap; self.fixes = fixes
    }
}

/// One sentence of the field text with the text before it (LM context).
public struct SentenceReq {
    public let left: String
    public let sentence: String
    public init(left: String, sentence: String) { self.left = left; self.sentence = sentence }
}

/// The idle pass (port of SentenceCheck.kt): every word of a sentence re-scored with the rest of the sentence as right
/// context, so a fix that needs later words still shows up. Nothing is edited; the caller decides what to do.
public enum SentenceCheck {
    /// right context per word (words): enough for grammar, bounded cost
    public static let RIGHT_WORDS = 8
    public static let MAX_WORDS = 40

    /// sentence ranges (Character offsets): up to and including . ! ? (and following quotes/brackets) or a newline
    public static func split(_ text: String) -> [Range<Int>] {
        let cs = Array(text)
        var out: [Range<Int>] = []
        var s = 0
        var i = 0
        let closers: Set<Character> = [".", "!", "?", "\"", "'", ")", "]"]
        while i < cs.count {
            let c = cs[i]
            if c == "\n" || c == "." || c == "!" || c == "?" {
                var e = i
                while e + 1 < cs.count && closers.contains(cs[e + 1]) { e += 1 }
                out.append(s..<(e + 1)); s = e + 1; i = e
            }
            i += 1
        }
        if s < cs.count { out.append(s..<cs.count) }
        return out.filter { r in cs[r].contains { $0.isLetter } }
    }

    /// -> fixes for the words of req.sentence whose best candidate beats the word as typed by minGap
    public static func check(_ c: Corrector, _ req: SentenceReq, scorer: LmScorer, params p: DecodeParams, minGap: Double,
                             cancelled: () -> Bool = { false }) throws -> [SentenceFix] {
        let cs = Array(req.sentence)
        let words = Array(segRanges(req.sentence).prefix(MAX_WORDS))
        var out: [SentenceFix] = []
        let user = c.user
        for (i, (a, b)) in words.enumerated() {
            if cancelled() { break }
            let w = String(cs[a..<b])
            if let u = user, u.has(w) { continue }
            let full = c.candidates(w, nil)
            if full.typedIdx < 0 || c.canSkip(full) { continue }
            let s = full.subset(c.lmSubset(full))
            let ti = s.typedIdx
            if ti < 0 || s.cands.count < 2 { continue }
            let (left, sep) = TypingCore.splitLeft(req.left + String(cs[0..<a]))
            let endRight = i + RIGHT_WORDS < words.count ? words[i + RIGHT_WORDS].0 : cs.count
            let right = trimEnd(String(cs[b..<endRight]))
            let lp = try scorer.score(s.cands.map { LmReq(left, sep + $0 + right) })
            var (k, sc) = choose(s, lp, p.lamRe, p.bias, p.pen)
            if let u = user, k != ti {
                let pen = u.penalty(s.typed, s.cands[k])
                if pen > 0 {
                    sc[k] -= pen
                    k = 0
                    for j in 1..<max(sc.count, 1) where sc[j] > sc[k] { k = j }
                }
            }
            let gap = sc[k] - sc[ti]
            if k == ti || gap < minGap { continue }
            var fixes: [String] = []
            for j in stableDesc(sc) {
                let f = s.cands[j]
                if f.lowercased() == w.lowercased() || fixes.contains(f) { continue }
                fixes.append(f)
                if fixes.count == 3 { break }
            }
            if !fixes.isEmpty { out.append(SentenceFix(start: a, from: w, to: s.cands[k], gap: gap, fixes: fixes)) }
        }
        return out
    }

    static func trimEnd(_ s: String) -> String {
        var cs = Substring(s)
        while let l = cs.last, l.isWhitespace { cs = cs.dropLast() }
        return String(cs)
    }
}
