import CoreGraphics
import Foundation

/// Where text sits on screen when the field won't say directly (Chromium contenteditable answers AXBoundsForRange
/// with a zero rect). Pure: string widths come in as a function. Offsets are UTF-16.
public enum TextGeometry {
    /// Start offset of each child text node's text in the field text, matched in order (paragraph breaks and other
    /// characters between them are skipped); nil for a node that can't be placed.
    public static func childStarts(field: String, children: [String]) -> [Int?] {
        let f = field as NSString
        var cursor = 0
        return children.map { c in
            let len = (c as NSString).length
            guard len > 0, cursor <= f.length else { return nil }
            let r = f.range(of: c, options: [.literal], range: NSRange(location: cursor, length: f.length - cursor))
            guard r.location != NSNotFound else { return nil }
            cursor = r.location + len
            return r.location
        }
    }

    /// the child holding all of [start, start+length): (child index, offset inside it)
    public static func childFor(start: Int, length: Int, starts: [Int?], children: [String]) -> (index: Int, local: Int)? {
        for (i, s) in starts.enumerated() {
            guard let s = s else { continue }
            let len = (children[i] as NSString).length
            if start >= s && start + length <= s + len { return (i, start - s) }
        }
        return nil
    }

    /// The span of [local, local+length) inside a one-line text node whose frame is known: measured proportionally,
    /// so the font only has to be roughly right. nil for an empty node or a range outside it.
    public static func span(in text: String, local: Int, length: Int, frame: CGRect, width: (String) -> CGFloat) -> CGRect? {
        let ns = text as NSString
        guard length > 0, local >= 0, local + length <= ns.length, frame.width > 0 else { return nil }
        let all = width(text)
        guard all > 0 else { return nil }
        let x0 = width(ns.substring(to: local)) / all * frame.width
        let x1 = width(ns.substring(to: local + length)) / all * frame.width
        return CGRect(x: frame.minX + x0, y: frame.minY, width: max(1, x1 - x0), height: frame.height)
    }

    /// A word on the caret's line, from the caret rect: `between` is the text from the word's start to the caret,
    /// measured back from the caret. nil when it isn't on the caret's line or is too far back to trust.
    public static func beforeCaret(caret: CGRect, between: String, wordLength: Int, width: (String) -> CGFloat) -> CGRect? {
        let ns = between as NSString
        guard wordLength > 0, wordLength <= ns.length, ns.length <= 80, !between.contains("\n"), caret.height > 2 else { return nil }
        let back = width(between)
        let w = width(ns.substring(to: wordLength))
        guard w > 0 else { return nil }
        return CGRect(x: caret.minX - back, y: caret.minY, width: w, height: caret.height)
    }
}
