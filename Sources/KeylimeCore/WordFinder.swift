import Foundation

/// Finding a finished word in the field's text at its word end, and how long to wait for it. Chromium / Electron
/// (Discord, Slack) update their accessibility text a while after the key, so the word we know from our own key record
/// may not be in the field yet: the word end waits (without holding up anything else) until it shows up, or WAIT passes.
public enum WordFinder {
    /// a word end waits this long (seconds, from its separator key) for its word to show up in the field's text
    public static let WAIT = 0.5
    /// re-read the field this often while waiting (and on every value-changed notification)
    public static let POLL = 0.04
    /// the word may end this many UTF-16 units before the caret (its separator and a few more keys may have landed) ...
    public static let SLACK = 24
    /// ... plus one per key typed since its separator, up to this many
    public static let MAX_TYPED = 200
    /// a later word end waits at most this long for the one before it to be resolved (the previous-word context)
    public static let PREV_WAIT = 1.0

    /// The whole-word occurrence of `word` closest before the caret. text: the field's text from absolute offset `base`;
    /// caret: absolute. typedSince: keys typed after the word's separator (the caret may have moved on that far).
    /// notBefore: an absolute offset the word can't start before (the end of the word end before it). -> absolute start
    public static func locate(_ word: String, text: NSString, base: Int, caret: Int, typedSince: Int = 0, notBefore: Int? = nil) -> Int? {
        let w = Array(word.utf16)
        guard !w.isEmpty else { return nil }
        let c = caret - base
        var i = min(c - w.count, text.length - w.count)
        var lowest = max(0, c - w.count - SLACK - min(max(typedSince, 0), MAX_TYPED))
        if let nb = notBefore { lowest = max(lowest, nb - base) }
        while i >= lowest {
            if wholeWord(w, text, i) { return base + i }
            i -= 1
        }
        return nil
    }

    static func wholeWord(_ w: [UInt16], _ s: NSString, _ i: Int) -> Bool {
        guard i >= 0, i + w.count <= s.length else { return false }
        for k in 0..<w.count where s.character(at: i + k) != w[k] { return false }
        if i > 0 && MarkTracker.isWordUnit(s.character(at: i - 1)) { return false }
        if i + w.count < s.length && MarkTracker.isWordUnit(s.character(at: i + w.count)) { return false }
        return true
    }

    public enum Step: Equatable {
        /// go on with the word at this start
        case found(Int)
        /// not there yet: look again on the next value change or after POLL
        case wait
        /// waited long enough: give up on this word end
        case skip
    }

    /// waited: seconds since the separator key; final: no more waiting (the caret was moved, the field changed)
    public static func step(found: Int?, waited: Double, final: Bool = false) -> Step {
        if let f = found { return .found(f) }
        return final || waited >= WAIT ? .skip : .wait
    }

    /// The end of the last located word after an edit of [at, at+oldLen) -> newLen (nil: it was inside the edit).
    public static func shifted(_ end: Int, at: Int, oldLen: Int, newLen: Int) -> Int? {
        if end <= at { return end }
        if end >= at + oldLen { return end + newLen - oldLen }
        return nil
    }
}
