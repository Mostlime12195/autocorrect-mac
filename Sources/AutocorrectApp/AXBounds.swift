import AppKit
import ApplicationServices
import KeylimeCore

/// Where a range of the field is on screen, from whichever source this field answers (AX coordinates):
///  1. "range": AXBoundsForRange on the field (native text views), whole range, else first + last character
///  2. "markers": the text-marker API Chromium gives VoiceOver (AXTextMarkerForIndex ->
///     AXTextMarkerRangeForUnorderedTextMarkers -> AXBoundsForTextMarkerRange)
///  3. "child": the field's static-text children (contenteditable paragraphs / spans): AXBoundsForRange on the child,
///     else the child's frame measured proportionally (one-line children)
///  4. "caret": the caret rect (selected text-marker range, or a zero-length range) and the text between the word and
///     the caret measured in a system font of the caret's height (words on the caret's line only)
/// The first source that works is remembered per field and tried first next time. One session per overlay refresh,
/// so the child walk and the caret are looked up once.
final class BoundsSession {
    static let order = ["range", "markers", "child", "caret"]

    private let f: AXField
    private lazy var snap: AXField.Snapshot? = f.snapshot()
    private var children: (els: [AXUIElement], texts: [String], starts: [Int?])?
    private var caretRect: CGRect??

    init(_ f: AXField) { self.f = f }

    /// first source that answers; all: try every source and say what each gave
    func bounds(_ r: NSRange, all: Bool = false) -> (rect: CGRect?, detail: String) {
        var order = Self.order
        if let p = f.boundsSource, let i = order.firstIndex(of: p) { order.remove(at: i); order.insert(p, at: 0) }
        var notes: [String] = []
        var won: (CGRect, String)? = nil
        for s in order {
            let (rect, why) = source(s, r)
            if let rect = rect {
                notes.append("\(s): ok \(NSStringFromRect(rect))")
                if won == nil { won = (rect, s) }
                if !all { break }
            } else {
                notes.append("\(s): \(why)")
            }
        }
        if let (rect, s) = won {
            f.boundsSource = s
            return (rect, "via \(s)" + (all || notes.count > 1 ? " [" + notes.joined(separator: "; ") + "]" : ""))
        }
        return (nil, "no source worked [" + notes.joined(separator: "; ") + "]")
    }

    private func source(_ s: String, _ r: NSRange) -> (CGRect?, String) {
        switch s {
        case "range": return f.boundsDetailRange(r)
        case "markers": return markers(r)
        case "child": return child(r)
        default: return caret(r)
        }
    }

    // MARK: sources

    private func markers(_ r: NSRange) -> (CGRect?, String) {
        guard let a = f.param("AXTextMarkerForIndex", NSNumber(value: r.location)),
              let b = f.param("AXTextMarkerForIndex", NSNumber(value: NSMaxRange(r))) else { return (nil, "no AXTextMarkerForIndex") }
        guard let range = f.param("AXTextMarkerRangeForUnorderedTextMarkers", [a, b] as CFArray) else {
            return (nil, "no AXTextMarkerRangeForUnorderedTextMarkers")
        }
        return Self.rect(f.param("AXBoundsForTextMarkerRange", range), "AXBoundsForTextMarkerRange")
    }

    private func loadChildren() -> (els: [AXUIElement], texts: [String], starts: [Int?]) {
        if let c = children { return c }
        var els: [AXUIElement] = [], texts: [String] = []
        var stack: [(AXUIElement, Int)] = [(f.el, 0)]
        var seen = 0
        while let item = stack.popLast(), seen < 300 {
            let (e, depth) = item
            seen += 1
            if depth > 0, (AXField.attr(e, kAXRoleAttribute) as? String) == (kAXStaticTextRole as String) {
                if let t = AXField.attr(e, kAXValueAttribute) as? String, !t.isEmpty { els.append(e); texts.append(t) }
                continue
            }
            guard depth < 12, let kids = AXField.attr(e, kAXChildrenAttribute) as? [AnyObject] else { continue }
            for k in kids.reversed() where CFGetTypeID(k) == AXUIElementGetTypeID() {
                let c = k as! AXUIElement
                AXUIElementSetMessagingTimeout(c, AXField.timeout)
                stack.append((c, depth + 1))
            }
        }
        let field = snap?.text ?? ""
        let starts = TextGeometry.childStarts(field: snap?.base == 0 ? field : "", children: texts)
        let c = (els, texts, starts)
        children = c
        return c
    }

    private func child(_ r: NSRange) -> (CGRect?, String) {
        let c = loadChildren()
        if c.els.isEmpty { return (nil, "no static-text children") }
        guard let hit = TextGeometry.childFor(start: r.location, length: r.length, starts: c.starts, children: c.texts) else {
            return (nil, "\(c.els.count) children, none holds the range")
        }
        let i = hit.index, local = hit.local
        let el = c.els[i]
        AXUIElementSetMessagingTimeout(el, AXField.timeout)
        var cr = CFRange(location: local, length: r.length)
        if let arg = AXValueCreate(.cfRange, &cr) {
            var v: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, arg, &v) == .success,
               let rr = Self.rect(v, "").0 { return (rr, "") }
        }
        guard let frame = AXField.frame(el), frame.width > 0, frame.height > 2 else { return (nil, "child has no frame") }
        if frame.height > 34 { return (nil, "child spans several lines (\(Int(frame.height)) pt)") }
        let font = NSFont.systemFont(ofSize: max(8, frame.height * 0.72))
        let rect = TextGeometry.span(in: c.texts[i], local: local, length: r.length, frame: frame) { Self.width($0, font) }
        return rect == nil ? (nil, "couldn't measure inside the child") : (rect, "")
    }

    private func caret(_ r: NSRange) -> (CGRect?, String) {
        guard let s = snap, s.selLength == 0 else { return (nil, "no caret") }
        if caretRect == nil { caretRect = findCaret(s.caret) }
        guard let c = caretRect!, c.height > 2 else { return (nil, "no caret rect") }
        guard r.location <= s.caret, let between = s.sub(NSRange(location: r.location, length: s.caret - r.location)) else {
            return (nil, "range is after the caret")
        }
        let font = NSFont.systemFont(ofSize: max(8, c.height * 0.72))
        let rect = TextGeometry.beforeCaret(caret: c, between: between, wordLength: r.length) { Self.width($0, font) }
        return rect == nil ? (nil, "not on the caret's line") : (rect, "")
    }

    private func findCaret(_ at: Int) -> CGRect? {
        if let m = f.attr("AXSelectedTextMarkerRange"), let r = Self.rect(f.param("AXBoundsForTextMarkerRange", m), "", caret: true).0 { return r }
        var cr = CFRange(location: at, length: 0)
        if let arg = AXValueCreate(.cfRange, &cr), let r = Self.rect(f.param(kAXBoundsForRangeParameterizedAttribute, arg), "", caret: true).0 { return r }
        // the character before the caret: its right edge
        if at > 0 {
            var c1 = CFRange(location: at - 1, length: 1)
            if let arg = AXValueCreate(.cfRange, &c1), let r = Self.rect(f.param(kAXBoundsForRangeParameterizedAttribute, arg), "").0 {
                return CGRect(x: r.maxX, y: r.minY, width: 0, height: r.height)
            }
        }
        return nil
    }

    // MARK: helpers

    static func rect(_ v: CFTypeRef?, _ what: String, caret: Bool = false) -> (CGRect?, String) {
        guard let v = v, CFGetTypeID(v) == AXValueGetTypeID() else { return (nil, "no \(what)") }
        var rect = CGRect.zero
        guard AXValueGetValue(v as! AXValue, .cgRect, &rect) else { return (nil, "\(what) isn't a rect") }
        let ok = (caret ? rect.width >= 0 : rect.width > 0) && rect.height > 2 && rect.height < 200 && rect.width < 2000
            && !(rect.minX == 0 && rect.minY == 0)
        return ok ? (rect, "") : (nil, "unusable rect \(NSStringFromRect(rect))")
    }

    static func width(_ s: String, _ font: NSFont) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: font]).width
    }
}
