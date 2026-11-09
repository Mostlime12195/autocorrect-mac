import Foundation

/// Battery / latency knobs (same defaults as the Android keyboard).
public struct CorrectorConfig {
    /// LM-score only this many cheap-ranked lexicon candidates (+ typed string + confusion/contraction/split extras)
    public var lmTopK = 6
    /// skip the LM when the typed word's cheap score beats every other candidate by at least this (nats)
    public var skipMargin = 3.0
    /// ... and its spatial fit is within this many nats per letter of a perfect key-centre hit
    public var skipFitPerLetter = 0.6
    /// cheap path (no LM): the typed string gets this bonus so only clear typos get changed
    public var cheapKeepBias = 0.5
    /// only words this frequent (lexicon rank) can skip the LM
    public var skipMaxRank = 20000
    /// re-check the previous word only when its own decision went through the LM
    public var recheckOnlyIfScored = true
    /// early exit: a clear cheap leader (by this much) only needs the runner-up LM-scored
    public var adaptiveMargin = 4.0
    /// skip the re-check when the previous word won its first pass by this much (and isn't a confusion word)
    public var recheckSkipMargin = 6.0
    /// re-check only candidates within this many nats of the previous word's first-pass best (at most recheckMax)
    public var recheckWindow = 8.0
    public var recheckMax = 4
    public init() {}
}

/// The word that was just finished.
public struct WordInput {
    /// as typed, with case
    public let typed: String
    /// touches in key units, one per character; nil -> key centres
    public let touches: [Touch]?
    /// text before the word up to the end of the previous word (the LM's left context)
    public let left: String
    /// separator between the previous word and this one (" ", ", ", "" at the start, ...)
    public let sep: String
    public init(typed: String, touches: [Touch]? = nil, left: String, sep: String) {
        self.typed = typed; self.touches = touches; self.left = left; self.sep = sep
    }
}

/// The previous word, for the re-check pass.
public struct PrevWord {
    public let slot: Slot
    public let idx: Int
    public let left: String
    public let sep: String
    public let lmScored: Bool
    /// first-pass margin of the previous word's choice over its runner-up (0 = unknown)
    public let margin: Double
    /// first-pass scores per slot candidate (nil = re-check all)
    public let scores: [Double]?
    public init(slot: Slot, idx: Int, left: String, sep: String, lmScored: Bool, margin: Double = 0, scores: [Double]? = nil) {
        self.slot = slot; self.idx = idx; self.left = left; self.sep = sep; self.lmScored = lmScored; self.margin = margin; self.scores = scores
    }
}

public struct Recheck { public let from: String; public let to: String; public let idx: Int }

/// The previous word as typed, for merge candidates ("some thing" -> "something").
public struct MergeInput {
    public let prevTyped: String
    public let prevTouches: [Touch]?
    public init(prevTyped: String, prevTouches: [Touch]? = nil) { self.prevTyped = prevTyped; self.prevTouches = prevTouches }
}

public struct Merge { public let to: String; public let best: Double; public let keep: Double }

public final class WordResult {
    public let slot: Slot
    public let scores: [Double]
    public let lm: [Double]?
    public let chosen: Int
    public let out: String
    /// the LM was skipped because the typed word was a confident exact hit
    public let skipped: Bool
    /// no model: spatial + unigram prior only (or the word was kept without a decision)
    public let cheap: Bool
    public let nScored: Int
    public let nCands: Int
    public let ms: Double
    public let recheck: Recheck?
    public let merge: Merge?

    init(slot: Slot, scores: [Double], lm: [Double]?, chosen: Int, out: String, skipped: Bool, cheap: Bool, nScored: Int, nCands: Int,
         ms: Double, recheck: Recheck? = nil, merge: Merge? = nil) {
        self.slot = slot; self.scores = scores; self.lm = lm; self.chosen = chosen; self.out = out; self.skipped = skipped
        self.cheap = cheap; self.nScored = nScored; self.nCands = nCands; self.ms = ms; self.recheck = recheck; self.merge = merge
    }

    /// chosen score minus the best other score (first pass)
    public var margin: Double {
        var best = -Double.infinity
        for i in 0..<scores.count where i != chosen && scores[i] > best { best = scores[i] }
        return best == -Double.infinity ? 0 : scores[chosen] - best
    }
    public var changed: Bool { out != slot.typed }
    public var lmScored: Bool { !skipped && !cheap }

    /// suggestions, best first (no duplicates)
    public func ranked(_ n: Int = 3) -> [String] {
        let order = stableDesc(slot.cands.indices.map { scores[$0] })
        var out: [String] = []
        for i in order where !out.contains(slot.cands[i]) { out.append(slot.cands[i]); if out.count == n { break } }
        return out
    }
}

/// indices sorted by value, descending; ties keep index order (Kotlin's stable sortedByDescending)
func stableDesc(_ v: [Double]) -> [Int] {
    v.indices.sorted { a, b in v[a] != v[b] ? v[a] > v[b] : a < b }
}

public final class CorrectorStats {
    public var words = 0, lmSkipped = 0, cheapOnly = 0, lmRuns = 0
    public var lmMsTotal = 0.0
}

/// Word-at-a-time corrector (port of Corrector.kt, standard style): the LM runs only at word end, only on the top-K
/// cheap candidates, and not at all for confident exact hits; re-check of the previous word and merges as on Android.
public final class Corrector {
    public let gen: CandidateGenerator
    public var gen2: CandidateGeneratorV2?
    public var config: CorrectorConfig
    public var user: UserData?
    public let stats = CorrectorStats()

    public init(gen: CandidateGenerator, gen2: CandidateGeneratorV2? = nil, config: CorrectorConfig = CorrectorConfig(), user: UserData? = nil) {
        self.gen = gen; self.gen2 = gen2; self.config = config; self.user = user
    }

    public var lex: Lexicon { gen.lex }

    public func candidates(_ typed: String, _ touches: [Touch]?) -> Slot {
        var t = (touches?.count == typed.count ? touches : nil) ?? KeyGeom.keyTouches(typed)
        if t.isEmpty { t = KeyGeom.keyTouches("a") }
        let c = gen2?.generate(t, typed) ?? gen.generate(t, typed)
        let near = user?.near(typed) ?? []
        if near.isEmpty { return Slot.of(typed, c) }
        // personal dictionary words close to the typed string: spelling-model cost like any lexicon word + a small prior
        let have = Set(c.map { $0.text.lowercased() })
        let emit = gen.sp.emitTable(t)
        let extra = near.compactMap { w -> Cand? in
            if have.contains(w.lowercased()) { return nil }
            guard let code = gen.sp.wordCode(w.lowercased()) else { return nil }
            return Cand(w, gen.sp.score(emit, code), Kind.WORD, UserData.WORD_LOGP)
        }
        return Slot.of(typed, c + extra)
    }

    static let OOV_LOGP = -20.0

    private func cheapScore(_ s: Slot, _ i: Int) -> Double {
        var lp = s.logp?[i] ?? Self.OOV_LOGP
        if lp.isNaN { lp = Self.OOV_LOGP }
        return s.sp[i] + gen.priorW * lp
    }

    /// cheap suggestions while typing: spatial + unigram prior, typed string kept on near-ties
    public func suggest(_ typed: String, _ touches: [Touch]? = nil, n: Int = 3) -> [String] {
        let s = candidates(typed, touches)
        let sc = s.cands.indices.map { cheapScore(s, $0) + ($0 == s.typedIdx ? config.cheapKeepBias : 0) }
        var out: [String] = []
        for i in stableDesc(sc) where !out.contains(s.cands[i]) { out.append(s.cands[i]); if out.count == n { break } }
        return out
    }

    /// indices to LM-score: top-K cheap-ranked lexicon words + typed + every non-word kind / confusion extra
    public func lmSubset(_ s: Slot) -> [Int] {
        var k = config.lmTopK
        if k <= 0 || k >= s.cands.count { return Array(s.cands.indices) }
        let pool = s.cands.indices.filter { s.kind($0) == Kind.WORD && !(s.logp?[$0].isNaN ?? true) && $0 != s.typedIdx }
        let cs = pool.map { cheapScore(s, $0) }
        let ranked = stableDesc(cs).map { pool[$0] }
        if ranked.count >= 2 && cheapScore(s, ranked[0]) - cheapScore(s, ranked[1]) >= config.adaptiveMargin { k = min(k, 2) }
        var keep = Set(ranked.prefix(k))
        if s.typedIdx >= 0 { keep.insert(s.typedIdx) }
        let conf = Set(CONFUSIONS[s.typed.lowercased()] ?? [])
        for i in s.cands.indices where s.kind(i) != Kind.WORD || conf.contains(s.cands[i].lowercased()) { keep.insert(i) }
        return keep.sorted()   // original order -> same argmax tie-breaks as the full slot
    }

    /// true when the LM can't change the outcome much: confident exact lexicon hit, no alternatives worth a look
    public func canSkip(_ s: Slot) -> Bool {
        let ti = s.typedIdx
        if ti < 0 { return false }
        let tl = s.typed.lowercased()
        guard let rank = lex.index[tl], rank < config.skipMaxRank else { return false }
        if CONFUSIONS[tl] != nil { return false }
        if s.cands.indices.contains(where: { s.kind($0) != Kind.WORD }) { return false }
        let letters = tl.filter { $0 != "'" }.count
        if letters == 0 { return false }
        let perfect = Double(letters) * gen.sp.perfectLetter
        if perfect - s.sp[ti] > config.skipFitPerLetter * Double(letters) { return false }
        let mine = cheapScore(s, ti)
        for i in s.cands.indices where i != ti && cheapScore(s, i) > mine - config.skipMargin { return false }
        return true
    }

    /// Decide one finished word. scorer == nil -> cheap path. prev -> re-check pass for the previous word.
    public func correctWord(_ w: WordInput, scorer: LmScorer?, params p: DecodeParams, prev: PrevWord?, merge: MergeInput? = nil) throws -> WordResult {
        let t0 = Date()
        let full = candidates(w.typed, w.touches)
        return try decideSlot(full, w, scorer, p, prev, merge, t0)
    }

    private func touchesOf(_ typed: String, _ t: [Touch]?) -> [Touch] { (t?.count == typed.count ? t : nil) ?? KeyGeom.keyTouches(typed) }

    private func ms(_ t0: Date) -> Double { Date().timeIntervalSince(t0) * 1000 }

    func decideSlot(_ full: Slot, _ w: WordInput, _ scorer: LmScorer?, _ p: DecodeParams, _ prev: PrevWord?, _ merge: MergeInput?, _ t0: Date) throws -> WordResult {
        stats.words += 1
        let left = w.left, sep = w.sep
        if full.typedIdx < 0 && full.cands.isEmpty { return keep(full, t0) }
        // personal dictionary words are never corrected
        let u = user
        if let u = u, u.has(full.typed) { return keep(full, t0) }
        guard let scorer = scorer else {
            stats.cheapOnly += 1
            let sc = full.cands.indices.map { cheapScore(full, $0) + ($0 == full.typedIdx ? config.cheapKeepBias : 0) }
            var k = 0
            for i in 1..<max(sc.count, 1) where sc[i] > sc[k] { k = i }
            return WordResult(slot: full, scores: sc, lm: nil, chosen: k, out: full.cands[k], skipped: false, cheap: true, nScored: 0,
                              nCands: full.cands.count, ms: ms(t0))
        }
        let mergePossible = merge != nil && prev != nil && sep == " " && gen2?.mergeOk(merge!.prevTyped, w.typed) == true
        if !mergePossible && canSkip(full) {
            stats.lmSkipped += 1
            let sc = full.cands.indices.map { cheapScore(full, $0) }
            return WordResult(slot: full, scores: sc, lm: nil, chosen: full.typedIdx, out: full.cands[full.typedIdx], skipped: true, cheap: false,
                              nScored: 0, nCands: full.cands.count, ms: ms(t0))
        }
        let s = full.subset(lmSubset(full))
        let lp = try scorer.score(s.cands.map { LmReq(left, sep + $0) })
        var (k, sc) = choose(s, lp, p.lam, p.bias, p.pen)
        // an edit the user undid recently needs SUPPRESS_NATS more
        if let u = u, k != s.typedIdx {
            let pen = u.penalty(s.typed, s.cands[k])
            if pen > 0 {
                sc[k] -= pen
                k = 0
                for i in 1..<max(sc.count, 1) where sc[i] > sc[k] { k = i }
            }
        }
        var recheck: Recheck? = nil
        var mergeOut: Merge? = nil
        if let prev = prev, let pm = p.margin {
            let prevConfident = prev.margin >= config.recheckSkipMargin && CONFUSIONS[prev.slot.cands[prev.idx].lowercased()] == nil &&
                CONFUSIONS[prev.slot.typed.lowercased()] == nil
            if !prevConfident && (prev.lmScored || !config.recheckOnlyIfScored || mergePossible) {
                let nxt = sep + s.cands[k]
                let keepIdx = recheckSubset(prev)
                let ps = prev.slot.subset(keepIdx)
                let cur0 = keepIdx.firstIndex(of: prev.idx) ?? -1
                let lp2s = try scorer.score(ps.cands.map { LmReq(prev.left, prev.sep + $0 + nxt) })
                let (k2s, sc2s) = choose(ps, lp2s, p.lamRe, p.bias, p.pen)
                var sc2 = [Double](repeating: -.infinity, count: prev.slot.cands.count)
                for (j, i) in keepIdx.enumerated() { sc2[i] = sc2s[j] }
                let k2 = keepIdx[k2s]
                let prevCur = prev.slot.cands[prev.idx]
                var rePen = 0.0
                if let u = u, k2 != prev.idx { rePen = u.has(prevCur) ? .infinity : u.penalty(prevCur, prev.slot.cands[k2]) }
                if cur0 >= 0 && k2 != prev.idx && sc2[k2] - sc2[prev.idx] > pm + rePen {
                    recheck = Recheck(from: prev.slot.cands[prev.idx], to: prev.slot.cands[k2], idx: k2)
                }
                // merge of the previous token and this one (only across a single space)
                if let merge = merge, let g2 = gen2, sep == " ", g2.mergeOk(merge.prevTyped, w.typed) {
                    let mc = g2.mergeCandidates(touchesOf(merge.prevTyped, merge.prevTouches), merge.prevTyped,
                                                touchesOf(w.typed, w.touches), w.typed)
                    if !mc.isEmpty {
                        let msx = mc.map { applyCase($0.text, merge.prevTyped) }
                        let lpm = try scorer.score(msx.map { LmReq(prev.left, prev.sep + $0) })
                        let cur = recheck?.idx ?? prev.idx
                        let kd = s.kind(k)
                        let keepV = sc2[cur] + s.sp[k] + (k == s.typedIdx ? p.bias : 0) - (kd != Kind.WORD ? (p.pen[kd] ?? 0) : 0)
                        var best = -Double.infinity
                        var bj = -1
                        for j in msx.indices {
                            let v = round3(mc[j].sp) + p.lamRe * lpm[j] - (p.pen["merge"] ?? 0)
                            if v > best { best = v; bj = j }
                        }
                        if best > keepV { mergeOut = Merge(to: msx[bj], best: best, keep: keepV) }
                    }
                }
            }
        }
        stats.lmRuns += 1
        let dt = ms(t0)
        stats.lmMsTotal += dt
        return WordResult(slot: s, scores: sc, lm: lp, chosen: k, out: s.cands[k], skipped: false, cheap: false, nScored: s.cands.count,
                          nCands: full.cands.count, ms: dt, recheck: recheck, merge: mergeOut)
    }

    /// previous-word candidates worth re-checking: the current choice + those close to the first-pass best
    private func recheckSubset(_ prev: PrevWord) -> [Int] {
        guard let sc = prev.scores, let best = sc.max() else { return Array(prev.slot.cands.indices) }
        let near = stableDesc(sc).filter { sc[$0] >= best - config.recheckWindow }.prefix(config.recheckMax)
        return Array(Set(near + [prev.idx])).sorted()
    }

    private func keep(_ full: Slot, _ t0: Date) -> WordResult {
        let ti = max(full.typedIdx, 0)
        let sc = full.cands.indices.map { $0 == ti ? 0.0 : -1e9 }
        return WordResult(slot: full, scores: sc, lm: nil, chosen: ti, out: ti < full.cands.count ? full.cands[ti] : full.typed, skipped: true,
                          cheap: true, nScored: 0, nCands: full.cands.count, ms: ms(t0))
    }
}
