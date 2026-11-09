import Foundation

// Port of the Android engine's Keyboard.kt (itself a port of keyboard.py / web/site/keyboard.js): same iteration
// orders and tie-breaks, so candidate lists match the Python reference.

/// Keyboard geometry in model units: key width 1.0, row pitch ROW_H, rows offset 0 / 0.5 / 1.5.
public enum KeyGeom {
    public static let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    public static let rowOff: [Double] = [0.0, 0.5, 1.5]
    public static let ROW_H = 1.4
    public static let AREA = 10 * 3 * 1.4
    public static let NEG = -1e9

    /// ASCII code -> letter index (a..z), -1 otherwise
    public static let L2I: [Int] = {
        var a = [Int](repeating: -1, count: 128)
        for c in 0..<26 { a[97 + c] = c }
        return a
    }()

    static let qwertyCenters: ([Double], [Double]) = {
        var cx = [Double](repeating: 0, count: 26), cy = [Double](repeating: 0, count: 26)
        for (r, row) in rows.enumerated() {
            for (i, ch) in row.unicodeScalars.enumerated() {
                let li = Int(ch.value) - 97
                cx[li] = rowOff[r] + Double(i) + 0.5
                cy[li] = Double(r) * ROW_H + ROW_H / 2
            }
        }
        return (cx, cy)
    }()

    /// letter centres; follow the active layout via setCenters (engine thread only)
    public private(set) static var CX: [Double] = qwertyCenters.0
    public private(set) static var CY: [Double] = qwertyCenters.1

    /// Another layout: letter -> centre in model units (missing letters keep their QWERTY place).
    public static func setCenters(_ c: [Character: (Double, Double)]) {
        var cx = qwertyCenters.0, cy = qwertyCenters.1
        for (ch, xy) in c {
            guard let a = ch.asciiValue, a >= 97, a < 123 else { continue }
            cx[Int(a) - 97] = xy.0; cy[Int(a) - 97] = xy.1
        }
        CX = cx; CY = cy
    }

    public static func center(_ c: Character) -> Touch? {
        guard let a = c.lowercased().unicodeScalars.first?.value, a >= 97, a < 123, c.isASCII else { return nil }
        return Touch(x: CX[Int(a) - 97], y: CY[Int(a) - 97])
    }

    /// Key-centre touches for a typed string (apostrophe -> APOS), like keyboard.key_touches.
    public static func keyTouches(_ s: String) -> [Touch] {
        var out: [Touch] = []
        out.reserveCapacity(s.count)
        for c in s {
            if c == "'" { out.append(.apos) } else if let t = center(c) { out.append(t) }
        }
        return out
    }
}

/// One touch in key units. APOS (x < -50) marks an apostrophe.
public struct Touch: Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public var isApos: Bool { x < -50 }
    public static let apos = Touch(x: -100, y: -100)
}

public let CONFUSIONS: [String: [String]] = {
    let groups: [[String]] = [
        ["there", "their", "they're"], ["your", "you're"], ["its", "it's"], ["then", "than"],
        ["to", "too"], ["from", "form"], ["lose", "loose"], ["of", "off"],
        ["were", "where", "we're"], ["affect", "effect"], ["quite", "quiet"], ["whose", "who's"],
        ["accept", "except"], ["weather", "whether"], ["advice", "advise"], ["breath", "breathe"],
        ["past", "passed"], ["peace", "piece"], ["principal", "principle"], ["know", "now"],
        ["new", "knew"], ["right", "write"], ["hear", "here"], ["brake", "break"],
        ["sight", "site"], ["wear", "where"], ["buy", "by"], ["though", "through", "thought"],
        ["and", "an"], ["in", "on"], ["is", "it"], ["if", "of"], ["are", "our"],
        ["we", "were"], ["the", "they"], ["want", "went"], ["dose", "does"], ["lead", "led"],
        ["who", "how"], ["or", "of"], ["loose", "lose"], ["lightning", "lightening"],
        ["definitely", "defiantly"], ["angel", "angle"], ["desert", "dessert"], ["council", "counsel"],
    ]
    // insertion-ordered sets, like Kotlin's LinkedHashSet
    var m: [String: [String]] = [:]
    for g in groups {
        for w in g {
            var s = m[w] ?? []
            for x in g where x != w && !s.contains(x) { s.append(x) }
            m[w] = s
        }
    }
    return m
}()

private let LN2 = log(2.0)

/// numpy's logaddexp
@inline(__always) func lae(_ x: Double, _ y: Double) -> Double {
    if x == y { return x + LN2 }
    let t = x - y
    return t > 0 ? x + log1p(exp(-t)) : y + log1p(exp(t))
}

func isUpperASCII(_ c: Character) -> Bool { c >= "A" && c <= "Z" }
func isLowerASCII(_ c: Character) -> Bool { c >= "a" && c <= "z" }

public func applyCase(_ word: String, _ pattern: String) -> String {
    let letters = pattern.filter { isUpperASCII($0) || isLowerASCII($0) }
    if letters.count > 1 && letters.allSatisfy(isUpperASCII) { return word.uppercased() }
    if let f = letters.first, isUpperASCII(f) { return cap1(word) }
    return word
}

/// first character upper-cased (Kotlin take(1).uppercase() + drop(1))
public func cap1(_ s: String) -> String {
    guard let f = s.first else { return s }
    return String(f).uppercased() + s.dropFirst()
}

/// Python round(x, 3): correctly rounded from the exact binary value (printf does exactly that).
public func round3(_ x: Double) -> Double {
    if !x.isFinite { return x }
    return Double(String(format: "%.3f", x)) ?? x
}

public final class Lexicon {
    public let words: [String]
    public let logp: [Double]
    public let nletters: [Int]
    public let bag: [Float]
    public let codes: [[Int8]]
    public let index: [String: Int]

    public convenience init(path: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        self.init(tsv: data)
    }

    public init(tsv: Data) {
        var ws: [String] = []
        var cs: [Double] = []
        ws.reserveCapacity(110_000); cs.reserveCapacity(110_000)
        tsv.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let b = raw.bindMemory(to: UInt8.self)
            var i = 0
            let n = b.count
            while i < n {
                var j = i
                while j < n && b[j] != 10 { j += 1 }
                var end = j
                if end > i && b[end - 1] == 13 { end -= 1 }
                if end > i {
                    var t = i
                    while t < end && b[t] != 9 { t += 1 }
                    if t < end {
                        let w = String(decoding: UnsafeBufferPointer(rebasing: b[i..<t]), as: UTF8.self)
                        var c: Int64 = 0
                        var k = t + 1
                        while k < end && b[k] == 32 { k += 1 }
                        while k < end && b[k] >= 48 && b[k] <= 57 { c = c * 10 + Int64(b[k] - 48); k += 1 }
                        ws.append(w); cs.append(Double(c))
                    }
                }
                i = j + 1
            }
        }
        let n = ws.count
        var tot = 0.0
        for c in cs { tot += c }
        words = ws
        logp = cs.map { log($0 / tot) }
        var nl = [Int](repeating: 0, count: n)
        var bg = [Float](repeating: 0, count: n * 26)
        var cd: [[Int8]] = []
        cd.reserveCapacity(n)
        for i in 0..<n {
            var code: [Int8] = []
            var cnt = 0
            for u in ws[i].utf8 {
                if u == 39 { code.append(-1); continue }
                let li = u < 128 ? KeyGeom.L2I[Int(u)] : -1
                // the lexicon is a-z + apostrophe; anything else can't be typed on the model's keyboard
                code.append(Int8(max(li, 0)))
                if li >= 0 { bg[i * 26 + li] += 1; cnt += 1 }
            }
            nl[i] = cnt
            cd.append(code)
        }
        nletters = nl; bag = bg; codes = cd
        var idx: [String: Int] = [:]
        idx.reserveCapacity(n * 2)
        for i in 0..<n where idx[ws[i]] == nil { idx[ws[i]] = i }
        index = idx
    }

    public var size: Int { words.count }
}

public final class SpatialModel {
    public let sigma: Double
    public let eps: Double
    let lpHit, lpOm, lpDbl, lpIns, lpTr, lpAposKeep, lpAposDrop, lpRand: Double
    /// best possible per-letter emission (touch on the key centre) incl. the hit probability
    public let perfectLetter: Double

    public init(sigma: Double = 0.3, pOmit: Double = 0.01, pDouble: Double = 0.006, pIns: Double = 0.002,
                pTranspose: Double = 0.006, pAposDrop: Double = 0.4, eps: Double = 0.01) {
        self.sigma = sigma; self.eps = eps
        lpHit = log(1 - pOmit - pDouble - pIns)
        lpOm = log(pOmit); lpDbl = log(pDouble); lpIns = log(pIns); lpTr = log(pTranspose)
        lpAposKeep = log(1 - pAposDrop); lpAposDrop = log(pAposDrop)
        lpRand = log(1.0 / KeyGeom.AREA)
        let s2 = sigma * sigma
        perfectLetter = log((1 - eps) / (2 * Double.pi * s2) + eps / KeyGeom.AREA) + lpHit
    }

    public struct Emit {
        /// n x 26, row-major
        public var e: [Double]
        public var isApos: [Bool]
        public var n: Int { isApos.count }
        func slice(_ a: Int, _ b: Int) -> Emit { Emit(e: Array(e[(a * 26)..<(b * 26)]), isApos: Array(isApos[a..<b])) }
    }

    public func emitTable(_ touches: [Touch]) -> Emit {
        let s2 = sigma * sigma
        var e = [Double](repeating: 0, count: touches.count * 26)
        let cx = KeyGeom.CX, cy = KeyGeom.CY
        for (i, t) in touches.enumerated() {
            for j in 0..<26 {
                if t.isApos { e[i * 26 + j] = KeyGeom.NEG; continue }
                let dx = t.x - cx[j], dy = t.y - cy[j]
                let g = exp(-(dx * dx + dy * dy) / (2 * s2)) / (2 * Double.pi * s2)
                e[i * 26 + j] = log((1 - eps) * g + eps / KeyGeom.AREA)
            }
        }
        return Emit(e: e, isApos: touches.map { $0.isApos })
    }

    /// Forward algorithm over alignments of the touches to one word (code: letter ids, -1 = apostrophe).
    public func score(_ em0: Emit, _ code: [Int8]) -> Double {
        let n = em0.n, m = code.count
        let NEG = KeyGeom.NEG
        var om = [Double](repeating: 0, count: m)
        for j in 0..<m { om[j] = code[j] < 0 ? lpAposDrop : lpOm }
        var em = [Double](repeating: 0, count: n * m)
        var dbl = [Double](repeating: 0, count: n * m)
        var ins = [Double](repeating: 0, count: n)
        em0.e.withUnsafeBufferPointer { E in
            for i in 0..<n {
                let ap0 = em0.isApos[i]
                for j in 0..<m {
                    let ap = code[j] < 0
                    let e = E[i * 26 + (ap ? 0 : Int(code[j]))]
                    em[i * m + j] = ap ? (ap0 ? lpAposKeep : NEG) : e + lpHit
                    dbl[i * m + j] = ap ? NEG : e + lpDbl
                }
                ins[i] = (ap0 ? NEG : lpRand) + lpIns
            }
        }
        let w = m + 1
        var F = [Double](repeating: NEG, count: (n + 1) * w)
        F[0] = 0
        if m > 0 { for j in 1...m { F[j] = F[j - 1] + om[j - 1] } }
        if n > 0 {
            for i in 1...n {
                F[i * w] = F[(i - 1) * w] + ins[i - 1]
                if m == 0 { continue }
                for j in 1...m {
                    var a = F[(i - 1) * w + j - 1] + em[(i - 1) * m + j - 1]
                    a = lae(a, F[i * w + j - 1] + om[j - 1])
                    a = lae(a, F[(i - 1) * w + j] + ins[i - 1])
                    a = lae(a, F[(i - 1) * w + j] + dbl[(i - 1) * m + j - 1])
                    if i >= 2 && j >= 2 { a = lae(a, F[(i - 2) * w + j - 2] + lpTr + em[(i - 2) * m + j - 1] + em[(i - 1) * m + j - 2]) }
                    F[i * w + j] = a
                }
            }
        }
        return F[n * w + m]
    }

    /// nil when the word has a character the keyboard model doesn't know (digits, accents, ...)
    public func wordCode(_ w: String) -> [Int8]? {
        var out: [Int8] = []
        for u in w.lowercased().unicodeScalars {
            if u == "'" { out.append(-1); continue }
            guard u.value < 128, KeyGeom.L2I[Int(u.value)] >= 0 else { return nil }
            out.append(Int8(KeyGeom.L2I[Int(u.value)]))
        }
        return out
    }
}

/// Candidate kinds (v2 adds split / space / contr / contr_rw / gdrop; merges are separate).
public enum Kind {
    public static let WORD = "word"
    public static let SPLIT = "split"
    public static let SPACE = "space"
    public static let CONTR = "contr"
    public static let CONTR_RW = "contr_rw"
    public static let GDROP = "gdrop"
}

/// A candidate: lowercase text, spatial log-likelihood, kind, lexicon prior (NaN if not a lexicon word).
public struct Cand: Equatable {
    public var text: String
    public var sp: Double
    public var kind: String = Kind.WORD
    public var logp: Double = .nan
    public init(_ text: String, _ sp: Double, _ kind: String = Kind.WORD, _ logp: Double = .nan) {
        self.text = text; self.sp = sp; self.kind = kind; self.logp = logp
    }
    public static func == (a: Cand, b: Cand) -> Bool { a.text == b.text && a.sp == b.sp && a.kind == b.kind }
}

/// numpy float32 pairwise sum of |bag - soft| over the 26 letters (8 accumulators, then the tail)
@inline(__always) private func bagDist(_ bag: UnsafeBufferPointer<Float>, _ off: Int, _ soft: UnsafeBufferPointer<Float>) -> Float {
    var r0 = abs(bag[off] - soft[0]), r1 = abs(bag[off + 1] - soft[1]), r2 = abs(bag[off + 2] - soft[2]), r3 = abs(bag[off + 3] - soft[3])
    var r4 = abs(bag[off + 4] - soft[4]), r5 = abs(bag[off + 5] - soft[5]), r6 = abs(bag[off + 6] - soft[6]), r7 = abs(bag[off + 7] - soft[7])
    var i = 8
    while i < 24 {
        r0 = r0 + abs(bag[off + i] - soft[i]); r1 = r1 + abs(bag[off + i + 1] - soft[i + 1])
        r2 = r2 + abs(bag[off + i + 2] - soft[i + 2]); r3 = r3 + abs(bag[off + i + 3] - soft[i + 3])
        r4 = r4 + abs(bag[off + i + 4] - soft[i + 4]); r5 = r5 + abs(bag[off + i + 5] - soft[i + 5])
        r6 = r6 + abs(bag[off + i + 6] - soft[i + 6]); r7 = r7 + abs(bag[off + i + 7] - soft[i + 7])
        i += 8
    }
    var res: Float = ((r0 + r1) + (r2 + r3)) + ((r4 + r5) + (r6 + r7))
    res += abs(bag[off + 24] - soft[24])
    res += abs(bag[off + 25] - soft[25])
    return res
}

/// Candidates for one typed word. Port of keyboard.CandidateGenerator (k=16, prefilter=1500).
public final class CandidateGenerator {
    public let lex: Lexicon
    public let sp: SpatialModel
    public let k: Int
    public let prefilter: Int
    public let priorW: Double
    private var cheap: [Double]

    public init(lex: Lexicon, sp: SpatialModel, k: Int = 16, prefilter: Int = 1500, priorW: Double = 0.5) {
        self.lex = lex; self.sp = sp; self.k = k; self.prefilter = prefilter; self.priorW = priorW
        cheap = [Double](repeating: 0, count: lex.size)
    }

    /// The v1 list: top-k lexicon words by spatial + prior_w * log prior, then the typed string and its confusions.
    public func generate(_ touches: [Touch], _ typed: String) -> [Cand] {
        let emit = sp.emitTable(touches)
        var softD = [Double](repeating: 0, count: 26)
        var nL = 0
        for i in 0..<emit.n {
            if emit.isApos[i] { continue }
            nL += 1
            var l = emit.e[i * 26]
            for j in 1..<26 { l = lae(l, emit.e[i * 26 + j]) }
            for j in 0..<26 { softD[j] += exp(emit.e[i * 26 + j] - l) }
        }
        let soft = softD.map { Float($0) }
        let n = lex.size
        var nOk = 0
        lex.bag.withUnsafeBufferPointer { bag in
            soft.withUnsafeBufferPointer { sf in
                lex.nletters.withUnsafeBufferPointer { nlet in
                    lex.logp.withUnsafeBufferPointer { lp in
                        cheap.withUnsafeMutableBufferPointer { ch in
                            for i in 0..<n {
                                let dl = abs(nlet[i] - nL)
                                if dl > 2 { ch[i] = -1e9; continue }
                                ch[i] = -(Double(bagDist(bag, i * 26, sf)) + 1.5 * Double(dl)) + 0.15 * lp[i]
                                nOk += 1
                            }
                        }
                    }
                }
            }
        }
        let top = topByCheap(nOk)
        var scored = [Double](repeating: 0, count: top.count)
        for q in 0..<top.count { scored[q] = sp.score(emit, lex.codes[top[q]]) }
        let rank = (0..<top.count).map { scored[$0] + priorW * lex.logp[top[$0]] }
        let order = (0..<top.count).sorted { a, b in rank[a] != rank[b] ? rank[a] > rank[b] : top[a] < top[b] }
        var cands: [Cand] = []
        var names = Set<String>()
        for q in order.prefix(k) {
            let w = top[q]
            cands.append(Cand(lex.words[w], scored[q], Kind.WORD, lex.logp[w])); names.insert(lex.words[w])
        }
        let tl = typed.lowercased()
        var extra = [tl]
        if let c = CONFUSIONS[tl] { extra += c.sorted() }
        for w in extra {
            if names.contains(w) { continue }
            guard let code = sp.wordCode(w) else { continue }
            names.insert(w)
            cands.append(Cand(w, sp.score(emit, code), Kind.WORD, lex.index[w].map { lex.logp[$0] } ?? .nan))
        }
        return cands
    }

    /// Indices of the top `prefilter` words by cheap score (ties: lexicon order), same set as a full sort.
    private func topByCheap(_ nOk: Int) -> [Int] {
        let n = lex.size
        let want = min(prefilter, nOk)
        if want == 0 { return [] }
        var vals: [Double] = []
        vals.reserveCapacity(nOk)
        for i in 0..<n where cheap[i] > -1e8 { vals.append(cheap[i]) }
        vals.sort()
        let thr = vals[nOk - want]
        var above = 0
        for v in vals where v > thr { above += 1 }
        var tiesLeft = want - above
        var out: [Int] = []
        out.reserveCapacity(want)
        for i in 0..<n {
            let c = cheap[i]
            if c < -1e8 { continue }
            if c > thr { out.append(i) } else if c == thr && tiesLeft > 0 { out.append(i); tiesLeft -= 1 }
        }
        return out
    }
}

// --- message structure (corrector.segment)
/// words: [A-Za-z]+(?:'[A-Za-z]+)*  -> (range start, end) in Character offsets
public func segRanges(_ text: String) -> [(Int, Int)] {
    let cs = Array(text)
    var out: [(Int, Int)] = []
    var i = 0
    let n = cs.count
    func letter(_ c: Character) -> Bool { isLowerASCII(c) || isUpperASCII(c) }
    while i < n {
        if !letter(cs[i]) { i += 1; continue }
        let s = i
        while i < n && letter(cs[i]) { i += 1 }
        while i + 1 < n && cs[i] == "'" && letter(cs[i + 1]) {
            i += 1
            while i < n && letter(cs[i]) { i += 1 }
        }
        out.append((s, i))
    }
    return out
}

/// -> (seps (n+1), words (n))
public func segment(_ text: String) -> ([String], [String]) {
    let cs = Array(text)
    var seps: [String] = [], words: [String] = []
    var last = 0
    for (a, b) in segRanges(text) {
        seps.append(String(cs[last..<a])); words.append(String(cs[a..<b])); last = b
    }
    seps.append(String(cs[last...]))
    return (seps, words)
}

/// One word slot: cased candidates, rounded spatial scores, kinds, typed index.
public final class Slot {
    public let typed: String
    public let cands: [String]
    public let sp: [Double]
    public let typedIdx: Int
    public let kinds: [String]?
    public let logp: [Double]?

    public init(typed: String, cands: [String], sp: [Double], typedIdx: Int, kinds: [String]? = nil, logp: [Double]? = nil) {
        self.typed = typed; self.cands = cands; self.sp = sp; self.typedIdx = typedIdx; self.kinds = kinds; self.logp = logp
    }

    public func kind(_ i: Int) -> String { kinds?[i] ?? Kind.WORD }

    /// Sub-slot with only the given candidate indices (typed index remapped; -1 if the typed string was dropped).
    public func subset(_ idx: [Int]) -> Slot {
        Slot(typed: typed, cands: idx.map { cands[$0] }, sp: idx.map { sp[$0] }, typedIdx: idx.firstIndex(of: typedIdx) ?? -1,
             kinds: kinds.map { k in idx.map { k[$0] } }, logp: logp.map { l in idx.map { l[$0] } })
    }

    public static func of(_ typed: String, _ cands: [Cand]) -> Slot {
        let tl = typed.lowercased()
        return Slot(typed: typed, cands: cands.map { applyCase($0.text, typed) }, sp: cands.map { round3($0.sp) },
                    typedIdx: cands.firstIndex { $0.text == tl } ?? -1, kinds: cands.map { $0.kind }, logp: cands.map { $0.logp })
    }
}
