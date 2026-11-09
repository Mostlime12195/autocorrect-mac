import Foundation

/// String key compared by exact code points (Swift String equality uses canonical equivalence; SentencePiece doesn't).
struct PieceKey: Hashable {
    let s: String
    init(_ s: String) { self.s = s }
    static func == (a: PieceKey, b: PieceKey) -> Bool { a.s.unicodeScalars.elementsEqual(b.s.unicodeScalars) }
    func hash(into h: inout Hasher) { for u in s.unicodeScalars { h.combine(u.value) } }
}

/// SentencePiece BPE (identity normalizer, byte fallback). Port of Tokenizer.kt / web/site/tokenizer.js, which
/// reproduce sentencepiece 0.2 encode/decode. The vocab is the vocab*.json written by web/export_vocab.py.
public final class SPTokenizer {
    public let pieces: [String]
    let scores: [Float]
    let types: [Int]
    public let unkId: Int
    public let eosId: Int
    public let bosId: Int
    let addDummyPrefix: Bool
    let removeExtraWhitespaces: Bool
    let escapeWhitespaces: Bool
    let byteFallback: Bool
    let unkSurface: String
    private var normal: [PieceKey: Int] = [:]
    private var reserved: [PieceKey: Int] = [:]
    private var byteId = [Int](repeating: -1, count: 256)
    /// user-defined pieces, longest first, as scalar arrays
    private var user: [[Unicode.Scalar]] = []

    static let WS = "\u{2581}"
    static let T_NORMAL = 1, T_UNKNOWN = 2, T_CONTROL = 3, T_USER = 4, T_UNUSED = 5, T_BYTE = 6

    public init(pieces: [String], scores: [Float], types: [Int], unkId: Int, eosId: Int, bosId: Int, addDummyPrefix: Bool,
                removeExtraWhitespaces: Bool, escapeWhitespaces: Bool, byteFallback: Bool, unkSurface: String) {
        self.pieces = pieces; self.scores = scores; self.types = types
        self.unkId = unkId; self.eosId = eosId; self.bosId = bosId
        self.addDummyPrefix = addDummyPrefix; self.removeExtraWhitespaces = removeExtraWhitespaces
        self.escapeWhitespaces = escapeWhitespaces; self.byteFallback = byteFallback; self.unkSurface = unkSurface
        var u: [String] = []
        for i in 0..<pieces.count {
            let p = pieces[i], t = types[i]
            if t == Self.T_NORMAL || t == Self.T_USER || t == Self.T_UNUSED { normal[PieceKey(p)] = i } else { reserved[PieceKey(p)] = i }
            if t == Self.T_USER { u.append(p) }
            if t == Self.T_BYTE, let v = Int(String(Array(p)[3..<5]), radix: 16) { byteId[v] = i }
        }
        // Kotlin sortedByDescending { length } (stable, UTF-16 length)
        user = u.enumerated().sorted { a, b in
            let la = a.element.utf16.count, lb = b.element.utf16.count
            return la != lb ? la > lb : a.offset < b.offset
        }.map { Array($0.element.unicodeScalars) }
    }

    public static func fromJSON(_ data: Data) throws -> SPTokenizer {
        guard let v = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw EngineError.badVocab }
        guard let pieces = v["pieces"] as? [String], let scores = v["scores"] as? [NSNumber], let types = v["types"] as? [NSNumber]
        else { throw EngineError.badVocab }
        func int(_ k: String) throws -> Int { guard let n = v[k] as? NSNumber else { throw EngineError.badVocab }; return n.intValue }
        func bool(_ k: String) throws -> Bool { guard let n = v[k] as? Bool else { throw EngineError.badVocab }; return n }
        return SPTokenizer(pieces: pieces, scores: scores.map { $0.floatValue }, types: types.map { $0.intValue },
                           unkId: try int("unk_id"), eosId: try int("eos_id"), bosId: try int("bos_id"),
                           addDummyPrefix: try bool("add_dummy_prefix"), removeExtraWhitespaces: try bool("remove_extra_whitespaces"),
                           escapeWhitespaces: try bool("escape_whitespaces"), byteFallback: try bool("byte_fallback"),
                           unkSurface: (v["unk_surface"] as? String) ?? " \u{2047} ")
    }

    public var vocabSize: Int { pieces.count }

    public func pieceToId(_ p: String) -> Int { reserved[PieceKey(p)] ?? normal[PieceKey(p)] ?? unkId }

    func normalize(_ text0: String) -> [Unicode.Scalar] {
        var s = Array(text0.unicodeScalars)
        if removeExtraWhitespaces {
            var o: [Unicode.Scalar] = []
            o.reserveCapacity(s.count)
            for u in s { if u == " " && o.last == " " { continue }; o.append(u) }
            if o.first == " " { o.removeFirst() }
            if o.last == " " { o.removeLast() }
            s = o
        }
        if s.isEmpty { return [] }
        if addDummyPrefix { s.insert(" ", at: 0) }
        if escapeWhitespaces { let ws = Unicode.Scalar(0x2581)!; s = s.map { $0 == " " ? ws : $0 } }
        return s
    }

    public func encodePieces(_ text: String) -> [String] {
        let s = normalize(text)
        if s.isEmpty { return [] }
        var sym: [String] = []
        var frozen: [Bool] = []
        var i = 0
        while i < s.count {
            var hit: [Unicode.Scalar]? = nil
            for p in user where i + p.count <= s.count && s[i..<(i + p.count)].elementsEqual(p) { hit = p; break }
            if let p = hit {
                var str = String.UnicodeScalarView(); str.append(contentsOf: p)
                sym.append(String(str)); frozen.append(true); i += p.count; continue
            }
            sym.append(String(Character(s[i]))); frozen.append(false); i += 1
        }
        func pairScore(_ k: Int) -> Float {
            if frozen[k] || frozen[k + 1] { return -.infinity }
            guard let id = normal[PieceKey(sym[k] + sym[k + 1])] else { return -.infinity }
            return scores[id]
        }
        var sc: [Float] = []
        sc.reserveCapacity(sym.count)
        if sym.count >= 2 { for k in 0..<(sym.count - 1) { sc.append(pairScore(k)) } }
        while true {
            var best = -1
            var bs = -Float.infinity
            for k in 0..<sc.count where sc[k] > bs { bs = sc[k]; best = k }
            if best < 0 { break }
            sym[best] = sym[best] + sym[best + 1]
            sym.remove(at: best + 1); frozen.remove(at: best + 1); sc.remove(at: best)
            if best > 0 { sc[best - 1] = pairScore(best - 1) }
            if best < sym.count - 1 { sc[best] = pairScore(best) }
        }
        return sym
    }

    public func encode(_ text: String) -> [Int] {
        var ids: [Int] = []
        for p in encodePieces(text) {
            let id = pieceToId(p)
            if id == unkId && byteFallback {
                for b in p.utf8 { ids.append(byteId[Int(b)]) }
            } else { ids.append(id) }
        }
        return ids
    }

    /// Surface string per id, like sentencepiece's DecodeIds (bytes grouped into UTF-8 characters).
    public func decodeSurfaces(_ ids: [Int]) -> [String] {
        var out = [String](repeating: "", count: ids.count)
        var bosWs = true
        var any = false
        var bytes: [Int] = []
        var bstart = 0
        func flush(_ end: Int) {
            var off = 0
            while off < bytes.count {
                let (cp, n) = Self.utf8At(bytes, off)
                if cp < 0 { out[bstart + off] = "\u{FFFD}"; off += 1 } else {
                    out[bstart + off + n - 1] = String(Character(Unicode.Scalar(UInt32(cp))!)); off += n
                }
                any = true
            }
            bytes.removeAll(); bstart = end + 1
        }
        for i in 0..<ids.count {
            let id = ids[i]
            let t = types[id]
            if t == Self.T_BYTE {
                if bytes.isEmpty { bstart = i }
                bytes.append(Int(String(Array(pieces[id])[3..<5]), radix: 16) ?? 0); continue
            }
            flush(i)
            if any { bosWs = false }
            if t == Self.T_CONTROL { continue }
            if t == Self.T_UNKNOWN { out[i] = unkSurface; bosWs = false; any = true; continue }
            var p = pieces[id]
            if bosWs && (addDummyPrefix || removeExtraWhitespaces) && p.hasPrefix(Self.WS) { p = String(p.dropFirst()) }
            out[i] = p.replacingOccurrences(of: Self.WS, with: " ")
            bosWs = false; any = true
        }
        flush(ids.count)
        return out
    }

    public func decode(_ ids: [Int]) -> String { decodeSurfaces(ids).joined() }

    /// strict UTF-8 decode of one character at b[o]: (codepoint, length) or (-1, 1)
    private static func utf8At(_ b: [Int], _ o: Int) -> (Int, Int) {
        let c = b[o]
        if c < 0x80 { return (c, 1) }
        var n = 0, cp = 0, mn = 0
        if c >= 0xc2 && c <= 0xdf { n = 2; cp = c & 0x1f; mn = 0x80 }
        else if (c & 0xf0) == 0xe0 { n = 3; cp = c & 0x0f; mn = 0x800 }
        else if c >= 0xf0 && c <= 0xf4 { n = 4; cp = c & 0x07; mn = 0x10000 }
        else { return (-1, 1) }
        if o + n > b.count { return (-1, 1) }
        for k in 1..<n {
            let x = b[o + k]
            if (x & 0xc0) != 0x80 { return (-1, 1) }
            cp = (cp << 6) | (x & 0x3f)
        }
        if cp < mn || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff) { return (-1, 1) }
        return (cp, n)
    }
}

public enum EngineError: Error, CustomStringConvertible {
    case badVocab
    case ort(String)
    case closed
    public var description: String {
        switch self {
        case .badVocab: return "bad vocab file"
        case .ort(let s): return "onnxruntime: \(s)"
        case .closed: return "session closed"
        }
    }
}
