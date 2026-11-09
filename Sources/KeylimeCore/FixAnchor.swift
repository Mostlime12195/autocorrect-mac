import Foundation

/// Where (and whether) a fix decided a moment ago may be written now. Offsets are UTF-16, absolute in the field.
///
/// Rules: the text being replaced is found again by its content near where it was (typing elsewhere moves it); it
/// must still be exactly what the fix was decided on; and the word at the caret, the one still being typed (no
/// separator after it yet), is never touched. While the user is in the middle of a word, fixes wait for the next
/// separator or pause.
public enum FixAnchor {
    public enum Decision: Equatable {
        case apply(at: Int)
        /// not now: the user is mid-word, or the target is the word being typed
        case wait(String)
        /// never: the target changed or is gone
        case drop(String)
    }

    /// how far the target may have moved and still be found
    public static let SLACK = 64

    static func isWord(_ c: UInt16) -> Bool { MarkTracker.isWordUnit(c) }

    /// `old` sits at u[at...] with no word character joined on either side
    static func fits(_ u: [UInt16], _ w: [UInt16], _ at: Int) -> Bool {
        guard !w.isEmpty, at >= 0, at + w.count <= u.count else { return false }
        for i in 0..<w.count where u[at + i] != w[i] { return false }
        if at > 0 && isWord(u[at - 1]) && isWord(w[0]) { return false }
        if at + w.count < u.count && isWord(u[at + w.count]) && isWord(w[w.count - 1]) { return false }
        return true
    }

    /// text: the field's text from `base`; caret: absolute; start: where `old` was when the fix was decided.
    /// atCaretOK: an explicit user action on that word (a picked fix, an undo) may touch the word at the caret.
    /// typing: keys came in just now (mid-word only means "wait" while the user is actually typing; after a pause it
    /// doesn't).
    public static func check(text: String, base: Int = 0, caret: Int, old: String, start: Int, atCaretOK: Bool = false,
                             typing: Bool = true) -> Decision {
        let u = Array(text.utf16), w = Array(old.utf16)
        let rel = start - base
        var found: Int? = fits(u, w, rel) ? rel : nil
        if found == nil {
            for d in 1...SLACK {
                if fits(u, w, rel - d) { found = rel - d; break }
                if fits(u, w, rel + d) { found = rel + d; break }
            }
        }
        guard let a = found else { return .drop("the text changed") }
        let end = a + w.count, c = caret - base
        if atCaretOK { return .apply(at: base + a) }
        if c >= a && c <= end { return .wait("it's the word at the caret") }
        if c > end {
            // the user is typing a word right now (just after a word character): wait for the separator / pause
            if typing && c > 0 && c <= u.count && isWord(u[c - 1]) && c - 1 >= end && hasSeparator(u, end, c) {
                return .wait("the user is mid-word")
            }
            // something must separate the target from what follows it
            if end < u.count && isWord(u[end]) && isWord(w[w.count - 1]) { return .wait("no separator after it yet") }
        }
        return .apply(at: base + a)
    }

    static func hasSeparator(_ u: [UInt16], _ from: Int, _ to: Int) -> Bool {
        (from..<min(to, u.count)).contains { !isWord(u[$0]) }
    }

    /// The caret after replacing `r` with `newLength` units: kept in place relative to the text around it.
    public static func caretAfter(sel: NSRange, replaced r: NSRange, newLength: Int) -> NSRange {
        let end = r.location + r.length
        if sel.location >= end { return NSRange(location: sel.location + newLength - r.length, length: sel.length) }
        if sel.location > r.location { return NSRange(location: r.location + newLength, length: 0) }
        return sel
    }
}
