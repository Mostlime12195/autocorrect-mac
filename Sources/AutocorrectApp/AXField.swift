import AppKit
import ApplicationServices
import KeylimeCore
import os

/// The focused text element, read and written through Accessibility. Every call has a short timeout (Electron apps
/// answer slower than 50 ms when busy). Never call from the event-tap thread. Offsets and ranges are UTF-16.
final class AXField {
    static let timeout: Float = 0.1
    static let log = Logger(subsystem: "dev.mostlime.autocorrect-mac", category: "ax")
    let el: AXUIElement
    let pid: pid_t
    /// why the last write did what it did (for the status window)
    var lastWrite = ""
    /// the bounds source that last worked here (BoundsSession)
    var boundsSource: String?
    /// the last replace got the word selected (so typing over it would work)
    var lastSelectionOK = false

    /// parameterized attributes the element offers (for the status window)
    var parameterizedNames: [String] {
        var names: CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(el, &names) == .success, let n = names as? [String] else { return [] }
        return n
    }

    init(_ el: AXUIElement) {
        self.el = el
        var p: pid_t = 0
        AXUIElementGetPid(el, &p)
        pid = p
        AXUIElementSetMessagingTimeout(el, Self.timeout)
    }

    static func focused() -> AXField? { focused(app: 0).field }

    /// the focused element: system-wide, else asked of the frontmost app (Chromium / Electron sometimes only answer
    /// that way). -> the field, or why there's none
    static func focused(app pid: pid_t) -> (field: AXField?, why: String) {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, timeout)
        var f: CFTypeRef?
        let e1 = AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &f)
        if e1 == .success, let v = f, CFGetTypeID(v) == AXUIElementGetTypeID() { return (AXField(v as! AXUIElement), "") }
        guard pid > 0 else { return (nil, "no focused element (system-wide AX error \(e1.rawValue))") }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var g: CFTypeRef?
        let e2 = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &g)
        if e2 == .success, let v = g, CFGetTypeID(v) == AXUIElementGetTypeID() { return (AXField(v as! AXUIElement), "") }
        return (nil, "no focused element (AX errors: system-wide \(e1.rawValue), app \(e2.rawValue))")
    }

    /// for a remembered element when the focus query fails: still focused / still answering / gone
    func liveness() -> Liveness {
        if let v = attr(kAXFocusedAttribute) as? Bool { return v ? .focused : .dead }
        return selection != nil ? .answers : .dead
    }

    /// Focus discovery when the focused-element query keeps failing: tell the app again to expose its tree, ask it
    /// again, then search its focused window for the element that says it's focused and has a selection (bounded).
    static func discover(app pid: pid_t, bundleId: String?) -> AXField? {
        guard pid > 0 else { return nil }
        enableAccessibility(pid: pid, bundleId: bundleId)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        if let e = element(attr(app, kAXFocusedUIElementAttribute)) { return AXField(e) }
        guard let win = element(attr(app, kAXFocusedWindowAttribute)) else { return nil }
        var queue: [(AXUIElement, Int)] = [(win, 0)]
        var seen = 0
        let t0 = Date()
        while !queue.isEmpty && seen < 400 && Date().timeIntervalSince(t0) < 0.6 {
            let (e, depth) = queue.removeFirst()
            seen += 1
            if (attr(e, kAXFocusedAttribute) as? Bool) == true, attr(e, kAXSelectedTextRangeAttribute) != nil { return AXField(e) }
            guard depth < 30, let kids = attr(e, kAXChildrenAttribute) as? [AnyObject] else { continue }
            for k in kids where CFGetTypeID(k) == AXUIElementGetTypeID() {
                let c = k as! AXUIElement
                AXUIElementSetMessagingTimeout(c, timeout)
                queue.append((c, depth + 1))
            }
        }
        log.notice("focus discovery: nothing focused found in \(seen, privacy: .public) elements")
        return nil
    }

    /// AXValue + selected range readable? -> nil if yes, else why not
    func whyNotReadable() -> String? {
        var v: CFTypeRef?
        let ev = AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v)
        var r: CFTypeRef?
        let er = AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &r)
        if er != .success { return "no selected range (AX error \(er.rawValue))" }
        if ev != .success && count == nil { return "no text value (AX error \(ev.rawValue))" }
        if ev == .success && !(v is String) && count == nil { return "value isn't text" }
        return snapshot() == nil ? "text not readable" : nil
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
    /// screen rect of a range from whichever source this field answers (see BoundsSession)
    func bounds(_ r: NSRange) -> CGRect? { BoundsSession(self).bounds(r).rect }

    /// AXBoundsForRange, with what happened. Falls back to the first and last character joined, for fields that
    /// only answer single characters.
    func boundsDetailRange(_ r: NSRange) -> (rect: CGRect?, detail: String) {
        let (a, why) = rawBounds(r)
        if let a = a { return (a, "ok \(NSStringFromRect(a))") }
        guard r.length > 1 else { return (nil, why) }
        let (b, _) = rawBounds(NSRange(location: r.location, length: 1))
        let (c, _) = rawBounds(NSRange(location: NSMaxRange(r) - 1, length: 1))
        if let b = b, let c = c, abs(b.midY - c.midY) < b.height / 2 {
            let u = b.union(c)
            return (u, "ok from single characters \(NSStringFromRect(u)) (whole range: \(why))")
        }
        return (nil, why + (b == nil ? "; single characters failed too" : "; single characters on different lines"))
    }

    private func rawBounds(_ r: NSRange) -> (CGRect?, String) {
        var cr = CFRange(location: r.location, length: r.length)
        guard let arg = AXValueCreate(.cfRange, &cr) else { return (nil, "bad range") }
        var v: CFTypeRef?
        let e = AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, arg, &v)
        guard e == .success, let val = v, CFGetTypeID(val) == AXValueGetTypeID() else {
            return (nil, e == .success ? "answer isn't a rect" : "AX error \(e.rawValue) for range \(r.location)+\(r.length)")
        }
        var rect = CGRect.zero
        guard AXValueGetValue(val as! AXValue, .cgRect, &rect) else { return (nil, "answer isn't a rect") }
        guard rect.width > 0 && rect.height > 2 && rect.height < 200 && rect.width < 2000 else {
            return (nil, "unusable rect \(NSStringFromRect(rect))")
        }
        return (rect, "")
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
        lastSelectionOK = false
        guard var sel = selection else { return .unsupported }
        for _ in 0..<4 {
            usleep(8_000)
            guard let s2 = selection else { return .unsupported }
            if s2 == sel { break }
            sel = s2
        }
        guard let cur = read(r) else { lastWrite = "couldn't read the word"; return .unsupported }
        guard cur == old else { lastWrite = "text changed under us"; return .changed }
        guard setSelection(r) else { lastWrite = "setting the selection failed"; return .unsupported }
        // Chromium / Electron apply a selection change asynchronously: wait for it to show (never write without it,
        // or the text would go in at the caret)
        var selected = selection == r
        for _ in 0..<15 where !selected { usleep(10_000); selected = selection == r }
        if !selected { setSelection(sel); lastWrite = "selection never took (\(String(describing: selection)) != \(r))"; return .unsupported }
        lastSelectionOK = true
        guard setSelectedText(new) else { setSelection(sel); lastWrite = "setting the selected text failed"; return .unsupported }
        let nr = NSRange(location: r.location, length: (new as NSString).length)
        var landed = read(nr) == new
        for _ in 0..<6 where !landed { usleep(20_000); landed = read(nr) == new }
        var caret = sel
        if sel.location >= NSMaxRange(r) {
            caret.location += nr.length - r.length
        } else if sel.location > r.location {
            caret = NSRange(location: NSMaxRange(nr), length: 0)
        }
        if landed {
            setSelection(caret)
            var back = selection == caret
            for _ in 0..<5 where !back { usleep(10_000); back = selection == caret; if !back { setSelection(caret) } }
            lastWrite = back ? "ok" : "ok, caret restore unconfirmed"
            return .ok
        }
        if read(r) == old { setSelection(sel); lastWrite = "the new text never showed up"; return .unsupported }
        lastWrite = "text after the write isn't what we wrote"
        return .changed
    }

    /// The fallback for editors that ignore AXSelectedText: select the word through AX, type the replacement over the
    /// selection (keys from `type`, while the user's keys are held), verify, put the caret back.
    func replaceByTyping(_ r: NSRange, old: String, new: String, type: (String) -> Void) -> Write {
        guard let sel = selection else { lastWrite = "typed: no selection"; return .unsupported }
        guard read(r) == old else { lastWrite = "typed: text changed under us"; return .changed }
        guard setSelection(r) else { lastWrite = "typed: setting the selection failed"; return .unsupported }
        var selected = selection == r
        for _ in 0..<15 where !selected { usleep(10_000); selected = selection == r }
        guard selected else { setSelection(sel); lastWrite = "typed: selection never took"; return .unsupported }
        type(new)
        let nr = NSRange(location: r.location, length: (new as NSString).length)
        var landed = read(nr) == new
        for _ in 0..<16 where !landed { usleep(25_000); landed = read(nr) == new }
        guard landed else {
            if read(r) == old { setSelection(sel); lastWrite = "typed: nothing changed"; return .unsupported }
            lastWrite = "typed: text after typing isn't what we typed"
            return .changed
        }
        var caret = sel
        if sel.location >= NSMaxRange(r) { caret.location += nr.length - r.length } else if sel.location > r.location { caret = NSRange(location: NSMaxRange(nr), length: 0) }
        setSelection(caret)
        var back = selection == caret
        for _ in 0..<5 where !back { usleep(10_000); back = selection == caret; if !back { setSelection(caret) } }
        lastWrite = back ? "ok (typed over the selection)" : "ok (typed), caret restore unconfirmed"
        return .ok
    }

    // MARK: snapshots

    /// The field's text (a window around the caret for long documents) and the caret, in absolute UTF-16 offsets.
    struct Snapshot {
        let text: String
        let base: Int
        let caret: Int
        let selLength: Int
        let ns: NSString

        init(text t: String, base: Int, caret: Int, selLength: Int) {
            // web text fields hold spaces as no-break spaces: same length in UTF-16, so offsets don't move
            let text = t.contains("\u{00A0}") ? t.replacingOccurrences(of: "\u{00A0}", with: " ") : t
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
