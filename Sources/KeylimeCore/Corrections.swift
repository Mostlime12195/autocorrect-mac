import Foundation

// Opt-in upload events (schema autocorrect-events/2, docs/upload-schema.md): one scrubbed, word-level event per
// correction decision. Pure Swift so it's unit-tested; the app (TextLayer + Uploader) only feeds decisions in.

/// The on-device scrub rules. A token is 1-20 characters, has a letter, and holds only letters, combining marks and
/// ' ’ - . (so no digits, @, ://, spaces, slashes or other symbols).
public enum Scrub {
    public static let maxToken = 20
    private static let extra: Set<Unicode.Scalar> = ["'", "\u{2019}", "-", "."]

    static func isLetter(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    static func isMark(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    static func isDigit(_ s: Unicode.Scalar) -> Bool { s.properties.generalCategory == .decimalNumber }

    public static func tokenOk(_ t: String) -> Bool {
        let u = t.unicodeScalars
        guard !u.isEmpty, u.count <= maxToken, !t.contains("@"), !t.contains("://"), u.contains(where: isLetter) else { return false }
        return u.allSatisfy { isLetter($0) || isMark($0) || extra.contains($0) }
    }

    /// a word slot: 1...maxTokens allowed tokens joined by single spaces ("a lot")
    public static func wordOk(_ w: String?, maxTokens: Int) -> Bool {
        guard let w = w else { return false }
        let parts = w.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        return (1...maxTokens).contains(parts.count) && parts.allSatisfy(tokenOk)
    }

    /// a raw context token -> trimmed, lowercased token, or nil if it must be dropped
    public static func contextToken(_ raw: String) -> String? {
        if raw.unicodeScalars.contains(where: isDigit) || raw.contains("@") || raw.contains("://") { return nil }
        var u = Array(raw.unicodeScalars)
        while let f = u.first, !(isLetter(f) || isDigit(f)) { u.removeFirst() }
        while let l = u.last, !(isLetter(l) || isDigit(l)) { u.removeLast() }
        var s = String.UnicodeScalarView()
        s.append(contentsOf: u)
        let t = String(s).lowercased()
        return tokenOk(t) ? t : nil
    }

    private static func tokens(_ line: Substring) -> [String] {
        line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// the 2 tokens right before the word (same line), each scrubbed; dropped ones aren't replaced by older words
    public static func before(_ text: String?) -> [String] {
        guard let text = text, !text.isEmpty else { return [] }
        let line = text.split(separator: "\n", omittingEmptySubsequences: false).last ?? Substring(text)
        return tokens(line).suffix(2).compactMap(contextToken)
    }

    /// the token right after the word (same line), scrubbed
    public static func after(_ text: String?) -> [String] {
        guard let text = text, !text.isEmpty else { return [] }
        let line = text.split(separator: "\n", omittingEmptySubsequences: false).first ?? Substring(text)
        guard let first = tokens(line).first, let t = contextToken(first) else { return [] }
        return [t]
    }
}

public enum Kinds {
    /// letters only, lowercase, accents removed
    public static func fold(_ s: String) -> String {
        var v = String.UnicodeScalarView()
        v.append(contentsOf: s.lowercased().decomposedStringWithCanonicalMapping.unicodeScalars.filter(Scrub.isLetter))
        return String(v)
    }

    /// grammar (confusable swaps from later words), punctuation (same letters), real_word (typed is a known word), spelling
    public static func classify(typed: String, fix: String, rewind: Bool = false, typedInVocab: Bool) -> String {
        if rewind { return "grammar" }
        if fold(typed) == fold(fix) { return "punctuation" }
        return typedInVocab ? "real_word" : "spelling"
    }

    public static func marginBucket(_ m: Double) -> String {
        if m.isNaN || m < 1 { return "0-1" }
        if m < 2 { return "1-2" }
        if m < 4 { return "2-4" }
        if m < 8 { return "4-8" }
        return "8+"
    }
}

/// One correction decision, as the app sees it (text around the word still raw: it's scrubbed here).
public struct CorrectionDecision {
    public var typed: String
    public var suggestion: String
    /// the other fixes offered, best first (rank = index + 1)
    public var alternatives: [String]
    public var kind: String
    /// auto_applied_kept, auto_applied_undone, suggestion_picked, suggestion_ignored, not_a_typo, manual_fix
    public var outcome: String
    public var pickedRank: Int?
    public var final: String?
    /// how much the model preferred the suggestion over the word as typed (score units), nil = unknown
    public var margin: Double?
    /// raw text before / after the word (only the nearest words survive the scrub)
    public var textBefore: String?
    public var textAfter: String?
    public var model: String
    public var appVersion: String

    public init(typed: String, suggestion: String, alternatives: [String], kind: String, outcome: String, pickedRank: Int? = nil,
                final: String? = nil, margin: Double? = nil, textBefore: String? = nil, textAfter: String? = nil, model: String,
                appVersion: String) {
        self.typed = typed; self.suggestion = suggestion; self.alternatives = alternatives; self.kind = kind
        self.outcome = outcome; self.pickedRank = pickedRank; self.final = final; self.margin = margin
        self.textBefore = textBefore; self.textAfter = textAfter; self.model = model; self.appVersion = appVersion
    }
}

public enum CorrectionEvents {
    public static let platform = "mac"
    static let outcomes: Set<String> = ["auto_applied_kept", "auto_applied_undone", "suggestion_picked", "suggestion_ignored",
                                        "not_a_typo", "manual_fix"]
    static let kinds: Set<String> = ["spelling", "real_word", "grammar", "punctuation"]

    static func matches(_ s: String, _ pattern: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }

    static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// The upload event for a decision, or nil when the scrub (or a missing piece) drops it.
    public static func make(_ d: CorrectionDecision, id: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                            now: Date = Date()) -> [String: Any]? {
        guard outcomes.contains(d.outcome), kinds.contains(d.kind) else { return nil }
        // the word itself and its top fix must be clean, or there's no event at all
        guard Scrub.wordOk(d.typed, maxTokens: 1), Scrub.wordOk(d.suggestion, maxTokens: 2), d.suggestion != d.typed else { return nil }
        let model = d.model.lowercased()
        guard matches(model, "^[a-z0-9][a-z0-9_.-]{0,31}$"), matches(d.appVersion, "^[0-9A-Za-z][0-9A-Za-z.+_-]{0,31}$") else { return nil }
        // ranks follow the app's list; a scrubbed alternative is left out but keeps its rank
        var alts: [[String: Any]] = []
        var seen: Set<String> = [d.suggestion]
        for (i, w) in d.alternatives.prefix(3).enumerated() where Scrub.wordOk(w, maxTokens: 2) && !seen.contains(w) {
            seen.insert(w)
            alts.append(["w": w, "rank": i + 1])
        }
        var e: [String: Any] = [
            "v": 2, "id": id, "day": dayFormat.string(from: now), "type": "correction", "platform": platform,
            "app_version": d.appVersion, "model": model, "kind": d.kind, "typed": d.typed, "suggestion": d.suggestion,
            "outcome": d.outcome,
        ]
        if !alts.isEmpty { e["alternatives"] = alts }
        if d.outcome == "suggestion_picked" {
            guard let r = d.pickedRank, r == 0 || alts.contains(where: { $0["rank"] as? Int == r }) else { return nil }
            e["picked_rank"] = r
        }
        if d.outcome == "manual_fix" {
            guard let f = d.final, Scrub.wordOk(f, maxTokens: 2), f != d.typed, f != d.suggestion else { return nil }
            e["final"] = f
        }
        if let m = d.margin { e["margin"] = Kinds.marginBucket(m) }
        let before = Scrub.before(d.textBefore), after = Scrub.after(d.textAfter)
        if !before.isEmpty { e["before"] = before }
        if !after.isEmpty { e["after"] = after }
        return e
    }

    /// one JSON line (keys sorted, so the preview reads the same every time)
    public static func line(_ e: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: e, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// HTTP side of the upload, without the network (unit-tested): response handling, the envelope, the batch loop.
public enum UploadCore {
    public enum Action: Equatable { case advance, retry, split, skip }

    /// 2xx advances; 408 / 429 / 5xx / network error (-1) retry later; 413 halves the batch; any other 4xx skips it
    public static func classify(_ code: Int) -> Action {
        switch code {
        case 200...299: return .advance
        case 413: return .split
        case 408, 429: return .retry
        case 500...: return .retry
        case 400...499: return .skip
        default: return .retry
        }
    }

    public static let schema = "autocorrect-events/2"

    /// exactly schema, install_id, app_version, events (each line is one already-built event)
    public static func envelope(installId: String, appVersion: String, lines: [String]) -> Data? {
        let events = lines.compactMap { l in l.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } }
        let doc: [String: Any] = ["schema": schema, "install_id": installId, "app_version": appVersion, "events": events]
        return try? JSONSerialization.data(withJSONObject: doc, options: [.withoutEscapingSlashes])
    }

    public struct Drained: Equatable {
        /// lines from the front of the queue that are done with (sent, or skipped for good)
        public var consumed: Int
        public var sent: Int
        public var skipped: Int
        /// set when it stopped on a retryable error: (status, Retry-After seconds)
        public var retryCode: Int?
        public var retryAfter: Double?
    }

    /// Upload the queue front to back in batches of at most maxEvents; stops at the end or on the first retryable error.
    public static func drain(_ lines: [String], maxEvents: Int = 500, maxBytes: Int = 512 * 1024,
                             send: ([String]) -> (code: Int, retryAfter: Double?)) -> Drained {
        var d = Drained(consumed: 0, sent: 0, skipped: 0, retryCode: nil, retryAfter: nil)
        var batch = maxEvents
        while d.consumed < lines.count {
            var n = 0, bytes = 0
            while d.consumed + n < lines.count && n < batch && (n == 0 || bytes + lines[d.consumed + n].utf8.count < maxBytes) {
                bytes += lines[d.consumed + n].utf8.count + 1
                n += 1
            }
            let chunk = Array(lines[d.consumed..<(d.consumed + n)])
            let r = send(chunk)
            switch classify(r.code) {
            case .advance: d.sent += n
            case .split:
                if n > 1 { batch = n / 2; continue }
                d.skipped += 1
            case .skip: d.skipped += n   // permanent 4xx: the same bytes can never succeed
            case .retry:
                d.retryCode = r.code; d.retryAfter = r.retryAfter
                return d
            }
            d.consumed += n
        }
        return d
    }

    /// .../api/v1/upload -> .../api/v1/install/{id}
    public static func deleteURL(_ upload: String, installId: String) -> String {
        var u = upload
        while u.hasSuffix("/") { u.removeLast() }
        if let i = u.lastIndex(of: "/") { u = String(u[..<i]) }
        return u + "/install/" + installId
    }
}
