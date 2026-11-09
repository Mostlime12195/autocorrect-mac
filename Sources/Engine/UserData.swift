import Foundation

/// What the app learned from this user, kept on this Mac only (port of UserData.kt):
///  - personal dictionary: case-preserving words that are never corrected and are offered as candidates for near misses
///  - suppressions: an edit (typed -> chosen) the user undid that isn't a spelling fix; it needs SUPPRESS_NATS more
///    score for SUPPRESS_DAYS.
/// Files: dict = one word per line; learn = TSV "s<TAB>from<TAB>to<TAB>expiry_ms". Thread-safe.
public final class UserData {
    private let dictURL: URL?
    private let learnURL: URL?
    private let now: () -> Double
    private var words: [String: String] = [:]      // lowercase -> as added
    private var order: [String] = []                // lowercase keys, insertion order
    private var suppressed: [String: Double] = [:]    // "from\u{1}to" -> expiry (ms)
    private let lock = NSLock()

    public static let MAX_LEN = 48
    public static let SUPPRESS_NATS = 3.0
    public static let SUPPRESS_DAYS = 7.0
    /// unigram log-prior for dictionary words offered as candidates
    public static let WORD_LOGP = -11.0
    private static let SEP = "\u{1}"

    public init(dict: URL?, learn: URL?, now: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
        dictURL = dict; learnURL = learn; self.now = now
        if let d = dict, let text = try? String(contentsOf: d, encoding: .utf8) {
            for l in text.split(separator: "\n") {
                let w = l.trimmingCharacters(in: .whitespaces)
                if Self.valid(w) { put(w) }
            }
        }
        if let f = learn, let text = try? String(contentsOf: f, encoding: .utf8) {
            for l in text.split(separator: "\n") {
                let p = l.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                if p.count == 4 && p[0] == "s", let e = Double(p[3]) { suppressed[p[1] + Self.SEP + p[2]] = e }
            }
        }
    }

    private func put(_ w: String) {
        let k = w.lowercased()
        if words[k] == nil { order.append(k) }
        words[k] = w
    }

    public static func valid(_ w: String) -> Bool {
        guard !w.isEmpty, w.count <= MAX_LEN else { return false }
        var any = false
        for c in w {
            if c.isLetter || c.isNumber { any = true; continue }
            if c == "'" || c == "\u{2019}" || c == "-" { continue }
            return false
        }
        return any
    }

    public func has(_ word: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !word.isEmpty && words[word.lowercased()] != nil
    }

    public var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return order.compactMap { words[$0] }
    }

    @discardableResult public func add(_ word: String) -> Bool {
        let w = word.trimmingCharacters(in: .whitespaces)
        guard Self.valid(w) else { return false }
        lock.lock(); defer { lock.unlock() }
        put(w)
        saveDict()
        return true
    }

    public func remove(_ word: String) {
        lock.lock(); defer { lock.unlock() }
        let k = word.trimmingCharacters(in: .whitespaces).lowercased()
        if words.removeValue(forKey: k) != nil { order.removeAll { $0 == k }; saveDict() }
    }

    /// dictionary words near a typed word (length +-2, edit distance <= 2), for the candidate list
    public func near(_ typed: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        if words.isEmpty { return [] }
        let t = typed.lowercased()
        return order.compactMap { k -> String? in
            guard let w = words[k] else { return nil }
            let l = Array(k), tc = Array(t)
            return k != t && abs(l.count - tc.count) <= 2 && Self.editDistance(l, tc, 2) <= 2 ? w : nil
        }
    }

    /// extra score the edit typed -> chosen needs (0 unless the user undid it recently)
    public func penalty(_ typed: String, _ chosen: String) -> Double {
        lock.lock(); defer { lock.unlock() }
        guard let e = suppressed[typed.lowercased() + Self.SEP + chosen.lowercased()] else { return 0 }
        return e > now() ? Self.SUPPRESS_NATS : 0
    }

    public func suppress(_ typed: String, _ chosen: String) {
        lock.lock(); defer { lock.unlock() }
        let t = now()
        suppressed = suppressed.filter { $0.value > t }
        suppressed[typed.lowercased() + Self.SEP + chosen.lowercased()] = t + Self.SUPPRESS_DAYS * 86_400_000
        saveLearn()
    }

    private func saveDict() {
        guard let f = dictURL else { return }
        try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = order.compactMap { words[$0] }.map { $0 + "\n" }.joined()
        try? text.write(to: f, atomically: true, encoding: .utf8)
    }

    private func saveLearn() {
        guard let f = learnURL else { return }
        try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        let t = now()
        var s = ""
        for (k, v) in suppressed where v > t {
            let ab = k.components(separatedBy: Self.SEP)
            if ab.count == 2 { s += "s\t\(ab[0])\t\(ab[1])\t\(Int64(v))\n" }
        }
        try? s.write(to: f, atomically: true, encoding: .utf8)
    }

    /// Levenshtein distance, stopping early above `max`
    static func editDistance(_ a: [Character], _ b: [Character], _ mx: Int) -> Int {
        if abs(a.count - b.count) > mx { return mx + 1 }
        if a.isEmpty { return b.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            var best = cur[0]
            if !b.isEmpty {
                for j in 1...b.count {
                    cur[j] = min(min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                    best = min(best, cur[j])
                }
            }
            if best > mx { return mx + 1 }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}
