import Foundation

// Opt-in upload events (schema autocorrect-events/3, docs/upload-schema.md): one scrubbed, word-level event per
// correction decision. Pure Swift so it's unit-tested; the app (TextLayer + Uploader) only feeds decisions in.
// With the separate "Palantir Mode" opt-in (and only then) an event also carries ctx_before / ctx_after:
// the rest of the current sentence around the word, clipped and scrubbed by Ctx.

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
        let line = text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }).last ?? Substring(text)
        return tokens(line).suffix(2).compactMap(contextToken)
    }

    /// the token right after the word (same line), scrubbed
    public static func after(_ text: String?) -> [String] {
        guard let text = text, !text.isEmpty else { return [] }
        let line = text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }).first ?? Substring(text)
        guard let first = tokens(line).first, let t = contextToken(first) else { return [] }
        return [t]
    }
}

/// Sentence context for the "Palantir Mode" opt-in (docs/upload-schema.md "Sentence context"). The same
/// rules, in the same order, as the reference in the autocorrect repo (collect/server.py ctx_token, collect/ctx_ref.py);
/// CorrectionsTests replays that reference's vectors (CtxVectors.swift).
///
/// Context = the current sentence only, on the word's own line, at most 24 words before and 12 after. Every token that
/// could identify someone or is a number, code or key is replaced by a placeholder before anything is queued.
public enum Ctx {
    public static let maxBefore = 24
    public static let maxAfter = 12
    public static let maxCtxToken = 32
    public static let placeholders: Set<String> = ["<num>", "<email>", "<url>", "<handle>", "<tok>"]
    static let punct = Set("'\u{2019}\u{2018}\"\u{201c}\u{201d}-\u{2013}\u{2014}.,!?;:()\u{2026}&\u{bf}\u{a1}\u{ab}\u{bb}".unicodeScalars)
    static let newlines = Set("\n\r\u{0b}\u{0c}\u{85}\u{2028}\u{2029}".unicodeScalars)
    static let sentenceEnd = Set(".!?\u{2026}\u{3002}\u{ff01}\u{ff1f}".unicodeScalars)
    static let closers = Set("\"'\u{201d}\u{2019})]}\u{bb}".unicodeScalars)
    static let vowels = Set("aeiouyAEIOUY".unicodeScalars)

    static func isSpace(_ s: Unicode.Scalar) -> Bool { s.properties.isWhitespace || (0x1c...0x1f).contains(s.value) }

    static func isNumber(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }

    static func str<S: Sequence>(_ u: S) -> String where S.Element == Unicode.Scalar {
        var v = String.UnicodeScalarView()
        v.append(contentsOf: u)
        return String(v)
    }

    /// one whitespace-separated token -> the token itself, or the placeholder that is sent instead of it
    public static func token(_ t: String) -> String {
        let u = Array(t.unicodeScalars)
        if u.isEmpty || u.contains(where: isSpace) { return "<tok>" }
        var a = 0, b = u.count
        while a < b, punct.contains(u[a]) { a += 1 }
        while b > a, punct.contains(u[b - 1]) { b -= 1 }
        let core = Array(u[a..<b])
        let atSign: Unicode.Scalar = "@", hash: Unicode.Scalar = "#", dot: Unicode.Scalar = ".", slash: Unicode.Scalar = "/"
        let hyphen: Unicode.Scalar = "-", underscore: Unicode.Scalar = "_"
        if let at = core.firstIndex(of: atSign), at > 0, at < core.count - 1 { return "<email>" }
        if t.contains("://") || str(core).lowercased().hasPrefix("www.") { return "<url>" }
        let host = Array(core.prefix(while: { $0 != slash }))
        if host.contains(dot) {
            let labels = host.split(separator: dot, omittingEmptySubsequences: false).map { Array($0) }
            if let last = labels.last, labels.allSatisfy({ !$0.isEmpty }), last.count >= 2, last.allSatisfy(Scrub.isLetter),
               labels.dropLast().allSatisfy({ l in l.allSatisfy { Scrub.isLetter($0) || isNumber($0) || $0 == hyphen || $0 == underscore } }) {
                return "<url>"
            }
        }
        if u.count - a >= 2, u[a] == atSign || u[a] == hash, Scrub.isLetter(u[a + 1]) || isNumber(u[a + 1]) || u[a + 1] == underscore {
            return "<handle>"
        }
        let hasDigit = u.contains(where: isNumber)
        let hasLetter = u.contains(where: Scrub.isLetter)
        if hasDigit { return hasLetter ? "<tok>" : "<num>" }
        if core.count > Scrub.maxToken || u.count > maxCtxToken { return "<tok>" }
        if !u.allSatisfy({ Scrub.isLetter($0) || Scrub.isMark($0) || punct.contains($0) }) { return "<tok>" }
        if !hasLetter { return u.count <= 3 ? t : "<tok>" }   // punctuation on its own (a dash, an ellipsis)
        // letters that look like a code or key
        let letters = core.filter(Scrub.isLetter)
        var ups = 0
        if letters.count > 1 {
            for i in 1..<letters.count where letters[i - 1].properties.isLowercase && letters[i].properties.isUppercase { ups += 1 }
        }
        if ups >= 3 { return "<tok>" }
        if core.filter({ $0 == hyphen }).count >= 2 && !letters.contains(where: { $0.properties.isLowercase }) { return "<tok>" }
        if letters.count >= 6 && letters.allSatisfy({ $0.value < 128 }) && !letters.contains(where: { vowels.contains($0) }) { return "<tok>" }
        return t
    }

    static func split(_ line: [Unicode.Scalar]) -> [String] {
        line.split(whereSeparator: isSpace).map { str($0) }
    }

    public static func endsSentence(_ tok: String) -> Bool {
        var u = Array(tok.unicodeScalars)
        while let l = u.last, closers.contains(l) { u.removeLast() }
        guard let l = u.last else { return false }
        return sentenceEnd.contains(l)
    }

    /// tokens -> what is sent ("" = nothing): placeholders in, runs of <num> collapsed, nothing unless a real word is left
    public static func scrub(_ toks: [String]) -> String {
        var out: [String] = []
        for t in toks {
            let s = token(t)
            if s == "<num>" && out.last == "<num>" { continue }
            out.append(s)
        }
        guard out.contains(where: { !placeholders.contains($0) && $0.unicodeScalars.contains(where: Scrub.isLetter) }) else { return "" }
        return out.joined(separator: " ")
    }

    /// ctx_before from the text right before the word. truncated = `left` is a window that may start in the middle of a
    /// word (its first token is then left out unless a sentence or line start is found after it).
    public static func before(_ left: String?, truncated: Bool = false) -> String {
        guard let left = left, !left.isEmpty else { return "" }
        let u = Array(left.unicodeScalars)
        let cut = u.lastIndex(where: { newlines.contains($0) }) ?? -1
        var line = Array(u[(cut + 1)...])
        if let l = line.last, !isSpace(l) {   // stuck to the word (an opening quote, "well-"): not context
            var i = line.count
            while i > 0, !isSpace(line[i - 1]) { i -= 1 }
            line = Array(line[..<i])
        }
        let toks = split(line)
        var start = 0
        for (i, t) in toks.enumerated() where endsSentence(t) { start = i + 1 }
        if start == 0 && truncated && cut < 0 { start = 1 }
        return scrub(Array(toks.dropFirst(start).suffix(maxBefore)))
    }

    /// ctx_after from the text right after the word (truncated: a window that may end in the middle of a word)
    public static func after(_ right: String?, truncated: Bool = false) -> String {
        guard let right = right, !right.isEmpty else { return "" }
        let u = Array(right.unicodeScalars)
        let end = u.firstIndex(where: { newlines.contains($0) })
        var line = end.map { Array(u[..<$0]) } ?? u
        if let f = line.first, !isSpace(f) {   // stuck to the word ("," "." "'s")
            var i = 0
            while i < line.count, !isSpace(line[i]) { i += 1 }
            if endsSentence(str(line[..<i])) { return "" }
            line = Array(line[i...])
        }
        var out: [String] = []
        var done = false
        for t in split(line) {
            out.append(t)
            if endsSentence(t) { done = true; break }
        }
        if !done && truncated && end == nil && !out.isEmpty { out.removeLast() }
        return scrub(Array(out.prefix(maxAfter)))
    }

    /// a ctx value as the server accepts it (the last check before an event is queued)
    public static func ok(_ v: String, max: Int) -> Bool {
        if v.isEmpty || v.unicodeScalars.contains(where: { newlines.contains($0) }) { return false }
        let toks = v.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if toks.count > max { return false }
        var prev: String? = nil
        var words = 0
        for t in toks {
            if placeholders.contains(t) {
                if t == "<num>" && prev == "<num>" { return false }
            } else if token(t) != t {
                return false
            } else if t.unicodeScalars.contains(where: Scrub.isLetter) {
                words += 1
            }
            prev = t
        }
        return words > 0
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
    /// raw text before / after the word (only the nearest words survive the scrub; with the sentence-context opt-in,
    /// the rest of the word's sentence, scrubbed by Ctx)
    public var textBefore: String?
    public var textAfter: String?
    /// textBefore is a window that may start mid-word (it didn't reach the start of the field)
    public var beforeTruncated = true
    /// textAfter may end mid-word (a window, or the user is still typing there)
    public var afterTruncated = true
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

    /// The Mac's field check: nothing is recorded from a secure (password) field, while secure input is on, or in an
    /// excluded app. (It can't tell email / URL / number fields apart; the token rules still drop those tokens.)
    public static func recordable(secureField: Bool, secureInput: Bool, excludedApp: Bool) -> Bool {
        !secureField && !secureInput && !excludedApp
    }

    /// Apps that never produce upload events even when the user took them off the "excluded apps" list (that list is
    /// about corrections; this one is about data): password managers, keychains, authenticators, terminals / SSH.
    /// A bundle id, or a prefix of one ending in a dot.
    public static let neverSharedApps = [
        "com.1password.", "com.agilebits.", "com.bitwarden.", "com.lastpass.", "com.dashlane.", "org.keepassxc.keepassxc",
        "com.hicknhacksoftware.MacPass", "in.sinew.Enpass-Desktop", "com.nordpass.", "me.proton.pass.", "com.apple.keychainaccess",
        "com.apple.Passwords", "com.authy.", "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.", "net.kovidgoyal.kitty",
        "org.alacritty", "io.alacritty", "com.github.wez.wezterm", "com.mitchellh.ghostty", "co.zeit.hyper", "com.termius-dmg.mac",
    ]

    public static func neverShared(bundleId: String?) -> Bool {
        guard let b = bundleId?.lowercased() else { return false }
        return neverSharedApps.contains { let p = $0.lowercased(); return p.hasSuffix(".") ? b.hasPrefix(p) : b == p }
    }

    /// Sentence context is also never taken from search fields (the opt-in still gives word-level events there).
    public static func contextAllowed(subrole: String?) -> Bool { subrole != "AXSearchField" }
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
    /// includeContext: the "Palantir Mode" opt-in is on (and the field allows it); without it there is no
    /// ctx_before / ctx_after, whatever text the decision carries.
    public static func make(_ d: CorrectionDecision, includeContext: Bool = false,
                            id: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
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
            "v": 3, "id": id, "day": dayFormat.string(from: now), "type": "correction", "platform": platform,
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
        if includeContext {
            let cb = Ctx.before(d.textBefore, truncated: d.beforeTruncated), ca = Ctx.after(d.textAfter, truncated: d.afterTruncated)
            if Ctx.ok(cb, max: Ctx.maxBefore) { e["ctx_before"] = cb }
            if Ctx.ok(ca, max: Ctx.maxAfter) { e["ctx_after"] = ca }
        }
        return e
    }

    /// a queued line without its sentence context (what is sent while "Palantir Mode" is off)
    public static func withoutContext(_ line: String) -> String {
        guard line.contains("\"ctx_"), let data = line.data(using: .utf8),
              var e = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return line }
        e.removeValue(forKey: "ctx_before"); e.removeValue(forKey: "ctx_after")
        return self.line(e) ?? line
    }

    /// a queued line exactly as it is sent (the upload preview shows this)
    public static func outgoing(_ line: String, context: Bool) -> String { context ? line : withoutContext(line) }

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

    public static let schema = "autocorrect-events/3"

    /// exactly schema, install_id, app_version, events (each line is one already-built event). Sentence context is
    /// taken out again unless "Palantir Mode" is on right now (context).
    public static func envelope(installId: String, appVersion: String, lines: [String], context: Bool = false) -> Data? {
        let events = lines.compactMap { l in
            CorrectionEvents.outgoing(l, context: context).data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        }
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
