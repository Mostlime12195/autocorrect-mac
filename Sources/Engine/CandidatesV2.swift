import Foundation

/// Candidate generation v2 (port of CandidatesV2.kt / keyboard.CandidateGeneratorV2):
///   split / space : 2-3 lexicon words for one typed token (space omitted / c v b n m read as the space)
///   contr / contr_rw / gdrop : apostrophe and g-dropping expansions ("im" -> "i'm", "fuckin" -> "fucking")
///   merge candidates: two typed tokens read as one word (decided in the re-check step)
public final class CandidateGeneratorV2 {
    public let gen: CandidateGenerator
    public var lex: Lexicon { gen.lex }
    public var sp: SpatialModel { gen.sp }
    let V: Int
    public let common: Set<String>
    let segK, maxSplits, minSplit, maxSplit, maxSplit3: Int
    /// the space bar's x extent in key units (eval layout [3.5, 8.5])
    public var spaceBarX: [Double]
    private var index: [String: [Int]] = [:]
    private var expand: [String: [String]] = [:]
    private var shortIds1: [Int] = []
    private var shortIds2: [Int] = []

    static let SPACE_BAR_Y = 3 * KeyGeom.ROW_H + KeyGeom.ROW_H / 2
    static let SPACE_NEAR: Set<Character> = ["c", "v", "b", "n", "m"]
    static let LP_NOSPACE = log(0.01)
    static let LP_EXTRA_SPACE = log(0.01)
    static let SPLIT_SINGLE: Set<String> = ["a", "i"]

    public init(gen: CandidateGenerator, splitVocab: Int = 30000, shortVocab: Int = 10000, common: Int = 3000, segK: Int = 3,
                maxSplits: Int = 4, minSplit: Int = 3, maxSplit: Int = 24, maxSplit3: Int = 14, spaceBarX: [Double] = [3.5, 8.5]) {
        self.gen = gen
        self.segK = segK; self.maxSplits = maxSplits; self.minSplit = minSplit; self.maxSplit = maxSplit; self.maxSplit3 = maxSplit3
        self.spaceBarX = spaceBarX
        let lex = gen.lex
        V = min(splitVocab, lex.size)
        self.common = Set(lex.words.prefix(common))
        var short: [Int] = []
        var slen: [Int: Int] = [:]
        for i in 0..<V {
            let w = lex.words[i]
            let s = w.replacingOccurrences(of: "'", with: "")
            let sc = Array(s)
            if i < shortVocab && sc.count <= 3 && (sc.count > 1 || Self.SPLIT_SINGLE.contains(s)) { short.append(i); slen[i] = sc.count }
            if sc.count >= 2 {
                var keys = [s]
                if sc.count >= 3 { for k in 0..<sc.count { var d = sc; d.remove(at: k); keys.append(String(d)) } }
                for key in keys {
                    var l = index[key] ?? []
                    if l.last != i { l.append(i); index[key] = l }
                }
            }
            if w.contains("'") { expand[s, default: []].append(w) }
        }
        shortIds1 = short.filter { slen[$0]! <= 2 }
        shortIds2 = short.filter { slen[$0]! <= 3 }
    }

    private struct Seg { let rank: Double; let sp: Double; let id: Int }

    private func spaceEmit(_ t: Touch) -> Double {
        let dx = max(spaceBarX[0] - t.x, 0.0, t.x - spaceBarX[1])
        let dy = t.y - Self.SPACE_BAR_Y
        let s2 = sp.sigma * sp.sigma
        let g = exp(-(dx * dx + dy * dy) / (2 * s2)) / (2 * Double.pi * s2)
        return log((1 - sp.eps) * g + sp.eps / KeyGeom.AREA)
    }

    private func lookup(_ s: String, _ into: inout Set<Int>) {
        if let l = index[s] { for q in l { into.insert(q) } }
    }

    private func deletions(_ cs: [Character]) -> [String] {
        (0..<cs.count).map { j in var d = cs; d.remove(at: j); return String(d) }
    }

    private func segTop(_ em: SpatialModel.Emit, _ typed: [Character], _ a: Int, _ b: Int, _ memo: inout [Int: [Seg]]) -> [Seg] {
        let key = a * 1000 + b
        if let m = memo[key] { return m }
        let L = b - a
        let sc = Array(typed[a..<b])
        let ids: [Int]
        if L <= 1 { ids = shortIds1 } else if L == 2 { ids = shortIds2 } else {
            var got = Set<Int>()
            lookup(String(sc), &got)
            for d in deletions(sc) { lookup(d, &got) }
            ids = got.sorted()
        }
        let es = em.slice(a, b)
        let pw = gen.priorW
        let out = ids.map { i -> Seg in let s = sp.score(es, lex.codes[i]); return Seg(rank: s + pw * lex.logp[i], sp: s, id: i) }
            .sorted { x, y in x.rank != y.rank ? x.rank > y.rank : x.id < y.id }
        let top = Array(out.prefix(segK))
        memo[key] = top
        return top
    }

    private struct Bound { let a: Int; let b: Int; let lp: Double; let space: Bool }

    /// -> 2-3 word splits of one typed token
    public func splits(_ touches: [Touch], _ typed: String) -> [Cand] {
        let tl = typed.lowercased()
        let tc = Array(tl)
        let n = tc.count
        if n < minSplit || n > maxSplit || !Self.isAlpha(tl) || common.contains(tl) || touches.count != n || Self.mixedCase(typed) { return [] }
        let em = sp.emitTable(touches)
        var bounds: [Bound] = []
        for p in 1..<n { bounds.append(Bound(a: p, b: p, lp: Self.LP_NOSPACE, space: false)) }
        if n >= 3 { for k in 1..<(n - 1) where Self.SPACE_NEAR.contains(tc[k]) { bounds.append(Bound(a: k, b: k + 1, lp: spaceEmit(touches[k]) + sp.lpHit, space: true)) } }
        var memo: [Int: [Seg]] = [:]
        var res: [String: (Double, Double, String)] = [:]
        var order: [String] = []
        let W = lex.words
        func add(_ words: [Int], _ rank: Double, _ spv: Double, _ space: Bool) {
            let text = words.map { W[$0] }.joined(separator: " ")
            if let r = res[text] {
                if rank > r.0 { res[text] = (rank, spv, space ? Kind.SPACE : Kind.SPLIT) }
            } else {
                res[text] = (rank, spv, space ? Kind.SPACE : Kind.SPLIT); order.append(text)
            }
        }
        for b1 in bounds {
            let A = segTop(em, tc, 0, b1.a, &memo)
            let B = segTop(em, tc, b1.b, n, &memo)
            for x in A { for y in B { add([x.id, y.id], x.rank + b1.lp + y.rank, x.sp + b1.lp + y.sp, b1.space) } }
            if n > maxSplit3 { continue }
            for b2 in bounds {
                if b2.a <= b1.b { continue }
                let M = segTop(em, tc, b1.b, b2.a, &memo)
                if M.isEmpty { continue }
                let C = segTop(em, tc, b2.b, n, &memo)
                for x in A { for m in M { for c in C {
                    add([x.id, m.id, c.id], x.rank + b1.lp + m.rank + b2.lp + c.rank, x.sp + b1.lp + m.sp + b2.lp + c.sp, b1.space || b2.space)
                } } }
            }
        }
        let sorted = order.sorted { x, y in
            let rx = res[x]!.0, ry = res[y]!.0
            return rx != ry ? rx > ry : Self.kless(x, y)
        }
        return sorted.prefix(maxSplits).map { Cand($0, res[$0]!.1, res[$0]!.2) }
    }

    /// Kotlin String.compareTo: UTF-16 code unit order
    static func kless(_ a: String, _ b: String) -> Bool { a.utf16.lexicographicallyPrecedes(b.utf16) }

    /// the v1 list (labelled) + v2 extras
    public func generate(_ touches: [Touch], _ typed: String) -> [Cand] {
        let cands = gen.generate(touches, typed)
        let tl = typed.lowercased()
        let exp: [String] = tl.contains("'") ? [] : (expand[tl] ?? [])
        let gi = lex.index[tl + "g"]
        let gd: String? = (tl.hasSuffix("in") && tl.count >= 4 && gi != nil && gi! < V) ? tl + "g" : nil
        let ckind = lex.index[tl] != nil ? Kind.CONTR_RW : Kind.CONTR
        var out: [Cand] = []
        out.reserveCapacity(cands.count + 6)
        for c in cands {
            var x = c
            x.kind = exp.contains(c.text) ? ckind : (c.text == gd ? Kind.GDROP : Kind.WORD)
            out.append(x)
        }
        var have = Set(cands.map { $0.text })
        var extra = exp.filter { !have.contains($0) }
        if let g = gd, !have.contains(g) { extra.append(g) }
        if !extra.isEmpty {
            let em = sp.emitTable(touches)
            for w in extra {
                if have.contains(w) { continue }
                guard let code = sp.wordCode(w) else { continue }
                out.append(Cand(w, sp.score(em, code), w == gd ? Kind.GDROP : ckind, lex.index[w].map { lex.logp[$0] } ?? .nan))
                have.insert(w)
            }
        }
        for c in splits(touches, typed) where !have.contains(c.text) { out.append(c); have.insert(c.text) }
        return out
    }

    public func mergeOk(_ typed1: String, _ typed2: String) -> Bool {
        if Self.mixedCase(typed1) || Self.mixedCase(typed2) { return false }
        let t1 = typed1.lowercased(), t2 = typed2.lowercased()
        let n = t1.count + t2.count
        if !Self.isAlpha(t1) || !Self.isAlpha(t2) || n < 3 || n > maxSplit { return false }
        return !common.contains(t1) || !common.contains(t2) || lex.index[t1 + t2] != nil
    }

    /// two typed tokens read as one word (spurious space)
    public func mergeCandidates(_ touches1: [Touch], _ typed1: String, _ touches2: [Touch], _ typed2: String,
                                top: Int = 3, slack: Double = 12.0) -> [Cand] {
        if !mergeOk(typed1, typed2) { return [] }
        let t1 = typed1.lowercased(), t2 = typed2.lowercased()
        let s = t1 + t2
        var got = Set<Int>()
        lookup(s, &got)
        for d in deletions(Array(s)) { lookup(d, &got) }
        if got.isEmpty { return [] }
        func sc1(_ tc: [Touch], _ w: String) -> Double { sp.score(sp.emitTable(tc), sp.wordCode(w)!) }
        let ref = sc1(touches1, t1) + sc1(touches2, t2)
        let em = sp.emitTable(touches1 + touches2)
        var out: [(String, Double, Double)] = []
        for i in got.sorted() {
            let x = sp.score(em, lex.codes[i]) + Self.LP_EXTRA_SPACE
            if x >= ref - slack { out.append((lex.words[i], x, x + gen.priorW * lex.logp[i])) }
        }
        return out.sorted { a, b in a.2 != b.2 ? a.2 > b.2 : Self.kless(a.0, b.0) }.prefix(top).map { Cand($0.0, $0.1, Kind.WORD) }
    }

    static func isAlpha(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy(isLowerASCII) }
    /// camelCase / handle-like tokens (a capital after the first letter, not ALL CAPS): never split or merged
    static func mixedCase(_ s: String) -> Bool { s.dropFirst().contains(where: isUpperASCII) && s != s.uppercased() }
}
