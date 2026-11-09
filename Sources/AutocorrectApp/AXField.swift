import AppKit
import ApplicationServices

/// The focused text element, read and written through Accessibility. Every call has a 50 ms timeout. Never call from
/// the event-tap thread. Offsets and ranges are UTF-16, like AX ranges.
final class AXField {
    static let timeout: Float = 0.05
    let el: AXUIElement
    let pid: pid_t

    init(_ el: AXUIElement) {
        self.el = el
        var p: pid_t = 0
        AXUIElementGetPid(el, &p)
        pid = p
        AXUIElementSetMessagingTimeout(el, Self.timeout)
    }

    static func focused() -> AXField? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, timeout)
        var f: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &f) == .success, let v = f,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return AXField(v as! AXUIElement)
    }

    func same(_ o: AXField?) -> Bool { o.map { CFEqual(el, $0.el) } ?? false }

    // MARK: attributes

    static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    func attr(_ name: String) -> CFTypeRef? { Self.attr(el, name) }

    func param(_ name: String, _ arg: CFTypeRef) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(el, name as CFString, arg, &v) == .success ? v : nil
    }

    static func element(_ v: CFTypeRef?) -> AXUIElement? {
        guard let v = v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        let e = v as! AXUIElement
        AXUIElementSetMessagingTimeout(e, timeout)
        return e
    }

    var role: String? { attr(kAXRoleAttribute) as? String }
    var subrole: String? { attr(kAXSubroleAttribute) as? String }
    var isSecure: Bool { subrole == (kAXSecureTextFieldSubrole as String) || role == (kAXSecureTextFieldSubrole as String) }
    var value: String? { attr(kAXValueAttribute) as? String }
    var count: Int? { (attr(kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue }
    var window: AXUIElement? { Self.element(attr(kAXWindowAttribute)) }

    var selection: NSRange? {
        guard let v = attr(kAXSelectedTextRangeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        guard AXValueGetValue(v as! AXValue, .cfRange, &r), r.location >= 0, r.length >= 0 else { return nil }
        return NSRange(location: r.location, length: r.length)
    }

    func string(_ r: NSRange) -> String? {
        var cr = CFRange(location: r.location, length: r.length)
        guard let arg = AXValueCreate(.cfRange, &cr) else { return nil }
        return param(kAXStringForRangeParameterizedAttribute, arg) as? String
    }

    /// the text in r: StringForRange, else a slice of the value
    func read(_ r: NSRange) -> String? {
        if let s = string(r), (s as NSString).length == r.length { return s }
        guard let v = value else { return nil }
        let ns = v as NSString
        return NSMaxRange(r) <= ns.length ? ns.substring(with: r) : nil
    }

    /// screen rect (AX coordinates: top-left origin, y down) of a range; nil when the app doesn't say or says nonsense
    func bounds(_ r: NSRange) -> CGRect? {
        var cr = CFRange(location: r.location, length: r.length)
        guard let arg = AXValueCreate(.cfRange, &cr), let v = param(kAXBoundsForRangeParameterizedAttribute, arg),
              CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(v as! AXValue, .cgRect, &rect) else { return nil }
        return rect.width > 0 && rect.height > 2 && rect.height < 200 && rect.width < 2000 ? rect : nil
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = attr(el, kAXPositionAttribute), let s = attr(el, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &pt), AXValueGetValue(s as! AXValue, .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }

    /// where this field's text can be seen: the field ∩ its scroll area ∩ its window (AX coordinates)
    func visibleFrame() -> CGRect? {
        guard var f = Self.frame(el) else { return nil }
        if let p = Self.element(attr(kAXParentAttribute)), (Self.attr(p, kAXRoleAttribute) as? String) == (kAXScrollAreaRole as String),
           let pf = Self.frame(p) { f = f.intersection(pf) }
        if let w = window, let wf = Self.frame(w) { f = f.intersection(wf) }
        return f.isNull || f.isEmpty ? nil : f
    }

    // MARK: writes

    @discardableResult
    func setSelection(_ r: NSRange) -> Bool {
        var cr = CFRange(location: r.location, length: r.length)
        guard let v = AXValueCreate(.cfRange, &cr) else { return false }
        return AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v) == .success
    }

    func setSelectedText(_ s: String) -> Bool {
        AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, s as CFString) == .success
    }

    enum Write { case ok, unsupported, changed }

    /// Replace r (which must read `old`) with `new` as one edit: select it, set the selected text, put the caret back,
    /// verify by reading it again. unsupported: nothing changed and the field won't take AX writes (safe to fall back);
    /// changed: the text isn't what we expected (leave it alone).
    func replace(_ r: NSRange, old: String, new: String) -> Write {
        // keys already delivered may still be landing (Chromium updates its tree late): wait for a stable caret
        guard var sel = selection else { return .unsupported }
        for _ in 0..<4 {
            usleep(8_000)
            guard let s2 = selection else { return .unsupported }
            if s2 == sel { break }
            sel = s2
        }
        guard let cur = read(r) else { return .unsupported }
        guard cur == old else { return .changed }
        guard setSelection(r) else { return .unsupported }
        if selection != r {
            usleep(10_000)
            if selection != r { setSelection(sel); return .unsupported }
        }
        guard setSelectedText(new) else { setSelection(sel); return .unsupported }
        let nr = NSRange(location: r.location, length: (new as NSString).length)
        var landed = read(nr) == new
        for _ in 0..<3 where !landed { usleep(40_000); landed = read(nr) == new }
        var caret = sel
        if sel.location >= NSMaxRange(r) {
            caret.location += nr.length - r.length
        } else if sel.location > r.location {
            caret = NSRange(location: NSMaxRange(nr), length: 0)
        }
        if landed {
            if !setSelection(caret) || selection != caret { usleep(15_000); setSelection(caret) }
            return .ok
        }
        if read(r) == old { setSelection(sel); return .unsupported }
        return .changed
    }

    // MARK: snapshots

    /// The field's text (a window around the caret for long documents) and the caret, in absolute UTF-16 offsets.
    struct Snapshot {
        let text: String
        let base: Int
        let caret: Int
        let selLength: Int
        let ns: NSString

        init(text: String, base: Int, caret: Int, selLength: Int) {
            self.text = text; self.base = base; self.caret = caret; self.selLength = selLength; ns = text as NSString
        }

        var end: Int { base + ns.length }

        func sub(_ r: NSRange) -> String? {
            let rel = NSRange(location: r.location - base, length: r.length)
            return rel.location >= 0 && NSMaxRange(rel) <= ns.length ? ns.substring(with: rel) : nil
        }

        /// UTF-16 unit at an absolute offset
        func unit(_ abs: Int) -> UInt16? {
            let i = abs - base
            return i >= 0 && i < ns.length ? ns.character(at: i) : nil
        }
    }

    static let FULL_CHARS = 30_000
    static let WINDOW_CHARS = 8_000

    func snapshot() -> Snapshot? {
        guard let sel = selection else { return nil }
        if let n = count, n > Self.FULL_CHARS {
            let a = max(0, sel.location - Self.WINDOW_CHARS)
            let len = min(n - a, 2 * Self.WINDOW_CHARS)
            guard len > 0, let s = string(NSRange(location: a, length: len)) else { return nil }
            let snap = Snapshot(text: s, base: a, caret: sel.location, selLength: sel.length)
            return sel.location <= snap.end ? snap : nil
        }
        guard let v = value else { return nil }
        let snap = Snapshot(text: v, base: 0, caret: sel.location, selLength: sel.length)
        return sel.location <= snap.end ? snap : nil
    }

    // MARK: app setup

    /// Chromium browsers only build their web accessibility tree with this on (Grammarly does the same)
    static let chromium: Set<String> = ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
                                        "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi",
                                        "com.operasoftware.Opera", "org.chromium.Chromium"]

    /// Electron apps expose their text only with AXManualAccessibility; Chromium browsers with AXEnhancedUserInterface
    static func enableAccessibility(pid: pid_t, bundleId: String?) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if let b = bundleId, chromium.contains(b) {
            _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }
}
