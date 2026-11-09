import Foundation

/// An underlined word in a text field. Offsets are UTF-16 (what Accessibility ranges use), absolute in the field.
public struct Mark: Equatable {
    public let id: Int
    public var start: Int
    public let word: String
    public let fixes: [String]
    public let spelling: Bool
    public var length: Int { word.utf16.count }
    public var end: Int { start + length }
}

/// The underlines of one field, independent of Accessibility: marks follow edits and are dropped when their word
/// changes. The host feeds it the field text (or a window of it) whenever the field may have changed.
public final class MarkTracker {
    public private(set) var marks: [Mark] = []
    private var nextId = 1
    /// how far a mark may have moved (text inserted / deleted before it) and still be found
    public static let SLACK = 48
    public static let MAX = 64

    public init() {}

    public var isEmpty: Bool { marks.isEmpty }

    @discardableResult
    public func add(start: Int, word: String, fixes: [String], spelling: Bool) -> Mark {
        let m = Mark(id: nextId, start: start, word: word, fixes: fixes, spelling: spelling)
        nextId += 1
        marks.removeAll { $0.start < m.end && m.start < $0.end }
        marks.append(m)
        if marks.count > Self.MAX { marks.removeFirst(marks.count - Self.MAX) }
        return m
    }

    public func remove(id: Int) { marks.removeAll { $0.id == id } }
    public func removeAll() { marks.removeAll() }
    public func removeAll(word: String) { marks.removeAll { $0.word.lowercased() == word.lowercased() } }
    /// marks that start inside [from, to)
    public func removeAll(in r: Range<Int>) { marks.removeAll { r.contains($0.start) } }

    public func mark(id: Int) -> Mark? { marks.first { $0.id == id } }

    /// the mark covering a UTF-16 offset (word end inclusive: a caret right after the word counts)
    public func mark(at offset: Int) -> Mark? { marks.last { offset >= $0.start && offset <= $0.end } }

    /// text in [at, at + oldLen) became newLen long: later marks shift, overlapping ones go
    public func applyEdit(at: Int, oldLen: Int, newLen: Int) {
        let d = newLen - oldLen
        marks = marks.compactMap { m in
            if m.end <= at { return m }
            if m.start >= at + oldLen { var n = m; n.start += d; return n }
            return nil
        }
    }

    /// Re-locate every mark in `text`, which is the field's text from UTF-16 offset `base`: a mark whose word is still at
    /// its offset (as a whole word) stays; one found nearby moves there; one outside the text or gone is dropped.
    /// -> ids dropped
    @discardableResult
    public func reconcile(_ text: String, base: Int = 0) -> [Int] {
        let u = Array(text.utf16)
        var dropped: [Int] = []
        var kept: [Mark] = []
        for var m in marks {
            let w = Array(m.word.utf16)
            let rel = m.start - base
            if rel >= 0 && Self.wholeWord(u, w, at: rel) { kept.append(m); continue }
            if let at = Self.nearest(u, w, around: rel, slack: Self.SLACK) {
                m.start = base + at
                if !kept.contains(where: { $0.start < m.end && m.start < $0.end }) { kept.append(m); continue }
            }
            dropped.append(m.id)
        }
        marks = kept
        return dropped
    }

    public static func isWordUnit(_ c: UInt16) -> Bool {
        if (65...90).contains(c) || (97...122).contains(c) || (48...57).contains(c) || c == 39 || c == 0x2019 { return true }
        if c < 128 { return false }
        guard let s = Unicode.Scalar(c) else { return true }   // surrogate halves: part of a word, to be safe
        return CharacterSet.letters.contains(s)
    }

    /// w sits at u[at...] with no word character right before or after it
    static func wholeWord(_ u: [UInt16], _ w: [UInt16], at: Int) -> Bool {
        guard !w.isEmpty, at >= 0, at + w.count <= u.count else { return false }
        for i in 0..<w.count where u[at + i] != w[i] { return false }
        if at > 0 && isWordUnit(u[at - 1]) { return false }
        if at + w.count < u.count && isWordUnit(u[at + w.count]) { return false }
        return true
    }

    /// the whole-word occurrence of w closest to `around` (within slack)
    static func nearest(_ u: [UInt16], _ w: [UInt16], around: Int, slack: Int) -> Int? {
        for d in 0...slack {
            if wholeWord(u, w, at: around - d) { return around - d }
            if d > 0 && wholeWord(u, w, at: around + d) { return around + d }
        }
        return nil
    }
}
