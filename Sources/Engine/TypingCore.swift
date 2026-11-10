import Foundation

/// A key as the typing state machine sees it (the app maps CGEvents to these).
public enum KeyInput: Equatable {
    /// the characters a key produced (usually one; "\n" for return)
    case text(String)
    case backspace
    /// anything that moves the caret or changes the field: clicks, arrows, cmd/ctrl shortcuts, app switches
    case reset
}

/// A word end that may be corrected: the separator key is held back until it resolves.
public struct CorrectionJob {
    public let id: Int
    public let typed: String
    public let sep: String
    public let input: WordInput
    public let prev: PrevWord?
    public let merge: MergeInput?
    let prevOut: String?
    let prevSep: String
}

/// Text edit to synthesize: `deletes` backspaces, then type `text`.
public struct Injection: Equatable {
    public let deletes: Int
    public let text: String
}

/// An undone correction (typed -> out): the app turns it into "not a typo" knowledge.
public struct Undone: Equatable {
    public let typed: String
    public let out: String
    public init(typed: String, out: String) { self.typed = typed; self.out = out }
}

public enum KeyDecision {
    case pass
    /// swallow the separator, correct, then call resolve()
    case hold(CorrectionJob)
    /// swallow the backspace and apply this edit instead (undo of the last correction)
    case undo(Injection, Undone)
}

/// The text state machine behind the event tap, independent of AppKit so it can be unit tested.
///
/// It tracks the word being typed and the text typed before it since the last reset (clicks, arrows, shortcuts reset
/// everything: the caret may be anywhere then). At a separator after a correctable word it asks for a correction; the
/// host holds the separator (and queues every key after it) until resolve(), so the text before the caret is exactly
/// what we tracked when the edit is synthesized. Backspace right after a correction undoes it.
public final class TypingCore {
    public private(set) var word = ""
    /// text before the current word (since the last reset), at most CTX_CHARS
    public private(set) var context = ""
    private var keepTypedOnce = false
    private var nextId = 1
    private var pending: CorrectionJob?

    struct Prev { let slot: Slot; let idx: Int; let out: String; let lmScored: Bool; let typed: String; let margin: Double; let scores: [Double]? }
    private var prev: Prev?

    struct Last { let oldSpan: String; let newSpan: String; let sep: String; let prefixOld: String; let typed: String; let learnTyped: String; let out: String }
    private var last: Last?

    /// capitalize standalone i / i'm / i'll / i'd / i've (unless the user undid that edit)
    public var capI = true
    /// user penalty lookup for capI (typed, chosen) -> nats
    public var penalty: (String, String) -> Double = { _, _ in 0 }

    /// characters of text kept before the word (the app sets it from the context-length setting, ~5 per token)
    public static var CTX_CHARS = 400
    /// the stored context is trimmed in steps this big, so its start (and the model's context prefix) stays put
    static let CTX_SLACK = 1024

    /// Where the left context for text before `at` starts: at least `chars` back, on a multiple of `step`, so the
    /// start only moves every `step` characters (successive words share a prefix, which the scorer's cache reuses).
    public static func contextStart(_ at: Int, chars: Int, step: Int = 1024) -> Int {
        at <= chars ? 0 : ((at - chars) / step) * step
    }
    public static let MAX_WORD = 32
    public static let SEPARATORS: Set<Character> = [" ", "\n", ".", ",", "!", "?", ";", ":", ")", "\""]
    /// what may come right before a correctable word (no @handles, #tags, paths, mid-token words)
    static let OPENERS: Set<Character> = [" ", "\n", "\t", "(", "[", "{", "\"", "\u{201C}", "\u{2018}"]
    static let I_WORDS: Set<String> = ["i", "i'm", "i'll", "i'd", "i've"]

    public init() {}

    /// may a correctable word start right after this character (nil = start of the text)?
    public static func isOpener(_ c: Character?) -> Bool { c.map { OPENERS.contains($0) } ?? true }

    /// standalone i / i'm / i'll / i'd / i've -> capitalized, unless the user undid that edit
    public static func capIWords(_ text: String, penalty: (String, String) -> Double) -> String {
        text.split(separator: " ", omittingEmptySubsequences: false).map { w -> String in
            let s = String(w)
            return I_WORDS.contains(s) && penalty(s, "I" + s.dropFirst()) == 0 ? "I" + s.dropFirst() : s
        }.joined(separator: " ")
    }

    /// The formal style's comma after a word shown with a different case (its own sentence-start capital): keep what's
    /// shown. "if," over "If" -> "If,"
    public static func keepCase(_ new: String, of shown: String?) -> String {
        guard let s = shown, new.count > s.count, !new.hasPrefix(s), String(new.prefix(s.count)).lowercased() == s.lowercased(),
              new.dropFirst(s.count).allSatisfy({ $0.isPunctuation }) else { return new }
        return s + new.dropFirst(s.count)
    }

    public var isPending: Bool { pending != nil }

    public func reset() {
        word = ""; context = ""; keepTypedOnce = false; prev = nil; last = nil
    }

    public static func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "'" || c == "\u{2019}" }

    /// [A-Za-z]+(?:'[A-Za-z]+)*'?
    public static func correctable(_ w: String) -> Bool {
        let cs = Array(w)
        guard let f = cs.first, isLowerASCII(f) || isUpperASCII(f), cs.count <= MAX_WORD else { return false }
        var prevApos = false
        for (i, c) in cs.enumerated() {
            if isLowerASCII(c) || isUpperASCII(c) { prevApos = false; continue }
            if c == "'" && !prevApos { prevApos = true; if i == cs.count - 1 { return true }; continue }
            return false
        }
        return !prevApos
    }

    /// -> (text up to the end of the last word, separator after it)
    public static func splitLeft(_ before: String) -> (String, String) {
        guard let r = segRanges(before).last else { return ("", before) }
        let cs = Array(before)
        return (String(cs[0..<r.1]), String(cs[r.1...]))
    }

    private func append(_ s: String) {
        context += s
        if context.count > Self.CTX_CHARS + Self.CTX_SLACK { context = String(context.suffix(Self.CTX_CHARS)) }
    }

    /// One key. canCorrect: the app allows corrections right now (enabled, model ready, app not excluded, no secure input).
    public func key(_ k: KeyInput, canCorrect: Bool) -> KeyDecision {
        // the host queues keys while a correction is pending; never crash the tap if that's violated
        if pending != nil { return .pass }
        switch k {
        case .reset:
            reset(); return .pass
        case .backspace:
            if !word.isEmpty { word.removeLast(); last = nil; return .pass }
            if let l = last, !l.sep.contains("\n"), context.hasSuffix(l.newSpan + l.sep) {
                // undo: back to exactly what was typed, kept as typed at the next word end
                context = String(context.dropLast(l.newSpan.count + l.sep.count)) + l.prefixOld
                word = l.typed
                keepTypedOnce = true
                last = nil; prev = nil
                return .undo(Self.edit(l.newSpan + l.sep, l.oldSpan), Undone(typed: l.learnTyped, out: l.out))
            }
            if !context.isEmpty { context.removeLast() }
            prev = nil; last = nil
            return .pass
        case .text(let s0):
            let s = s0 == "\r" ? "\n" : s0
            guard s.count == 1, let c = s.first else {
                append(word + s); word = ""; keepTypedOnce = false; prev = nil; last = nil
                return .pass
            }
            if Self.isWordChar(c) { word.append(c); last = nil; return .pass }
            if Self.SEPARATORS.contains(c) {
                let opener = context.last.map { Self.OPENERS.contains($0) } ?? true
                if canCorrect && !word.isEmpty && !keepTypedOnce && opener && Self.correctable(word) {
                    let job = makeJob(sep: s)
                    pending = job
                    return .hold(job)
                }
                if !word.isEmpty { prev = nil }
                append(word + s); word = ""; keepTypedOnce = false; last = nil
                if c == "\n" { prev = nil }
                return .pass
            }
            append(word + s); word = ""; keepTypedOnce = false; prev = nil; last = nil
            return .pass
        }
    }

    private func makeJob(sep: String) -> CorrectionJob {
        let (left, sp) = Self.splitLeft(context)
        var prevWord: PrevWord? = nil
        var merge: MergeInput? = nil
        var prevOut: String? = nil
        var prevSep = ""
        if let p = prev, let r = segRanges(left).last, r.1 == left.count, String(Array(left)[r.0..<r.1]) == p.out {
            let (leftp, sepp) = Self.splitLeft(String(left.dropLast(p.out.count)))
            prevOut = p.out; prevSep = sp
            prevWord = PrevWord(slot: p.slot, idx: p.idx, left: leftp, sep: sepp, lmScored: p.lmScored, margin: p.margin, scores: p.scores)
            merge = MergeInput(prevTyped: p.typed)
        }
        let id = nextId
        nextId += 1
        prev = nil
        return CorrectionJob(id: id, typed: word, sep: sep, input: WordInput(typed: word, left: left, sep: sp), prev: prevWord, merge: merge,
                             prevOut: prevOut, prevSep: prevSep)
    }

    private func capIWords(_ text: String) -> String {
        guard capI else { return text }
        return Self.capIWords(text, penalty: penalty)
    }

    /// The held word end resolved: the correction result, or nil (too slow / skipped / failed).
    /// -> the edit to synthesize before the separator goes out (nil = none).
    public func resolve(_ job: CorrectionJob, _ r: WordResult?) -> Injection? {
        guard pending?.id == job.id else { return nil }
        pending = nil
        word = ""
        keepTypedOnce = false
        last = nil
        guard let r = r else {
            append(job.typed + job.sep)
            return nil
        }
        let hasPrev = job.prevOut != nil
        let mg = hasPrev ? r.merge : nil
        // the previous word's new text: its re-check and/or the formal style's comma after it
        let prevNew = (mg == nil && hasPrev) ? (r.prevText ?? r.recheck?.to).map { Self.keepCase(capIWords($0), of: job.prevOut) }
            .flatMap { $0 != job.prevOut ? $0 : nil } : nil
        let out = capIWords(mg?.to ?? r.out)
        let changed = out != job.typed || prevNew != nil
        if !changed {
            append(job.typed + job.sep)
            if job.sep != "\n" {
                prev = Prev(slot: r.slot, idx: r.chosen, out: job.typed, lmScored: r.lmScored, typed: job.typed,
                            margin: r.lmScored ? r.margin : 0, scores: r.lmScored ? r.scores : nil)
            }
            return nil
        }
        let prefixOld = (mg != nil || prevNew != nil) ? job.prevOut! + job.prevSep : ""
        let oldSpan = prefixOld + job.typed
        let newSpan = (prevNew.map { $0 + job.prevSep } ?? "") + out
        // the context ends with prefixOld (the word itself isn't in it yet)
        context = String(context.dropLast(prefixOld.count))
        append(newSpan + job.sep)
        last = Last(oldSpan: oldSpan, newSpan: newSpan, sep: job.sep, prefixOld: prefixOld, typed: job.typed,
                    learnTyped: mg != nil ? oldSpan : job.typed, out: out)
        if mg == nil && job.sep != "\n" {
            prev = Prev(slot: r.slot, idx: r.chosen, out: out, lmScored: r.lmScored, typed: job.typed,
                        margin: r.lmScored ? r.margin : 0, scores: r.lmScored ? r.scores : nil)
        }
        return Self.edit(oldSpan, newSpan)
    }

    /// text before the caret `from` -> `to`; the common prefix stays ("teh" -> "the" keeps the "t")
    static func edit(_ from: String, _ to: String) -> Injection {
        let o = Array(from), n = Array(to)
        var k = 0
        while k < o.count && k < n.count && o[k] == n[k] { k += 1 }
        return Injection(deletes: o.count - k, text: String(n[k...]))
    }
}
