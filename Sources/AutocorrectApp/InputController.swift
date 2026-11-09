import AppKit
import ApplicationServices
import Carbon
import Engine
import os

/// The event tap and the hold / inject machinery around TypingCore.
///
/// Ordering rule: the order in which events leave this tap is the order the app sees them. While a correction is
/// pending (the separator is held) or our synthesized edit is in flight, every real key / click is swallowed and
/// queued; queued events are replayed (as tagged copies) after the edit, and the edit only counts as done when its last
/// tagged event has come back through this tap. So keys are never lost or reordered, and the tap thread never waits on
/// inference: a correction that isn't back within holdMs is dropped and the separator goes out as typed.
final class InputController {
    private enum State { case idle, holding(Int), injecting(Int64) }

    private let engine: EngineHost
    private let settings = Settings.shared
    private let log = Logger(subsystem: "dev.mostlime.autocorrect-mac", category: "input")
    private let lock = NSLock()
    private let core = TypingCore()
    private var state = State.idle
    private var queue: [CGEvent] = []
    private var held: (job: CorrectionJob, sep: CGEvent, app: String?)?
    private var seq: Int64 = 0
    private let injectQ = DispatchQueue(label: "ac.inject", qos: .userInteractive)
    private let source = CGEventSource(stateID: .privateState)
    private var tap: CFMachPort?
    /// keys whose keyDown is queued, held or in flight: only their keyUps wait. Every other keyUp goes out at once,
    /// or the app sees the key as still down (press-and-hold accent menu, key repeat).
    private var heldDowns = Set<Int64>()
    /// recent decisions for "Copy Debug Log" (memory only)
    private var debug: [String] = []
    private let t0 = Date()

    // cached environment (updated from the main thread)
    private var frontApp: String?
    private var layout = KeyLayout.current()
    private(set) var tapRunning = false

    static let MAGIC: Int64 = 0x4143_0000_0000_0000   // "AC" in the high bytes
    static let MAGIC_MASK: Int64 = 0x7fff_0000_0000_0000

    /// stats for the menu
    private(set) var corrections = 0

    init(engine: EngineHost) {
        self.engine = engine
        core.penalty = { [weak engine] a, b in engine?.user.penalty(a, b) ?? 0 }
        frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let app = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            self?.appChanged(app)
        }
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
                                                            object: nil, queue: .main) { [weak self] _ in self?.layoutChanged() }
        engine.setLayout(layout.centers)
    }

    var frontmostBundleId: String? { lock.lock(); defer { lock.unlock() }; return frontApp }
    var layoutName: String { lock.lock(); defer { lock.unlock() }; return layout.name }

    private func appChanged(_ app: String?) {
        lock.lock()
        frontApp = app
        if case .idle = state { core.reset() }
        lock.unlock()
    }

    private func layoutChanged() {
        let l = KeyLayout.current()
        lock.lock(); layout = l; lock.unlock()
        engine.setLayout(l.centers)
    }

    // MARK: tap

    /// Start the tap on its own thread. false when it can't be created (no Accessibility permission yet).
    @discardableResult
    func start() -> Bool {
        if tapRunning { return true }
        let mask: CGEventMask = [CGEventType.keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                 .otherMouseDown, .otherMouseUp].reduce(0) { $0 | (1 << CGEventMask($1.rawValue)) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                        callback: { _, type, event, refcon in
                                            let c = Unmanaged<InputController>.fromOpaque(refcon!).takeUnretainedValue()
                                            return c.handle(type, event)
                                        }, userInfo: me) else { return false }
        tap = t
        tapRunning = true
        let th = Thread {
            let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: t, enable: true)
            CFRunLoopRun()
        }
        th.name = "ac-tap"
        th.qualityOfService = .userInteractive
        th.start()
        log.info("event tap started")
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let tag = event.getIntegerValueField(.eventSourceUserData)
        if tag & Self.MAGIC_MASK == Self.MAGIC {
            // one of ours coming back through the tap
            let s = tag & 0xffff_ffff
            lock.lock()
            if case .injecting(let a) = state, a == s { injectQ.async { self.echoed(s) } }
            lock.unlock()
            return Unmanaged.passUnretained(event)
        }
        lock.lock()
        defer { lock.unlock() }
        if case .idle = state {} else {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if type == .keyUp && !heldDowns.contains(code) { return Unmanaged.passUnretained(event) }
            if type == .keyDown { heldDowns.insert(code) }
            if let c = event.copy() { queue.append(c) }
            return nil
        }
        switch process(type, event) {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .hold(let job):
            beginHold(job, event)
            return nil
        case .undo(let inj, let undone):
            let evs = synth(inj)
            if evs.isEmpty { return nil }
            note("undo del=\(inj.deletes) ins=\(inj.text.debugDescription)")
            heldDowns.insert(Int64(kVK_Delete))   // the swallowed backspace's keyUp waits for the edit
            state = .injecting(tagAll(evs))
            injectQ.async { self.post(evs) }
            learn(undone)
            return nil
        }
    }

    /// lock held
    private func process(_ type: CGEventType, _ e: CGEvent) -> KeyDecision {
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return core.key(.reset, canCorrect: false)
        case .keyDown:
            break
        default:
            return .pass
        }
        let flags = e.flags
        let code = CGKeyCode(e.getIntegerValueField(.keyboardEventKeycode))
        if flags.contains(.maskCommand) || flags.contains(.maskControl) { return core.key(.reset, canCorrect: false) }
        switch Int(code) {
        case kVK_Delete:
            return core.key(.backspace, canCorrect: false)
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown,
             kVK_ForwardDelete, kVK_Escape, kVK_Tab, kVK_Help:
            return core.key(.reset, canCorrect: false)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            return core.key(.text("\n"), canCorrect: canCorrect())
        default:
            break
        }
        var len = 0
        var buf = [UniChar](repeating: 0, count: 8)
        e.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &len, unicodeString: &buf)
        if len == 0 { return core.key(.reset, canCorrect: false) }   // dead key: an accent is being composed
        let s = String(utf16CodeUnits: buf, count: len)
        // control characters and function keys (U+F700 private range): not text
        if s.unicodeScalars.contains(where: { ($0.value < 32 && $0 != "\r" && $0 != "\n") || (0xF700...0xF8FF).contains($0.value) }) {
            return core.key(.reset, canCorrect: false)
        }
        return core.key(.text(s), canCorrect: canCorrect())
    }

    /// lock held
    private func canCorrect() -> Bool {
        settings.enabled && engine.ready && !layout.isInputMethod && !settings.isExcluded(frontApp) && !IsSecureEventInputEnabled()
    }

    /// lock held: the separator `sep` is swallowed until the correction resolves or times out
    private func beginHold(_ job: CorrectionJob, _ sep: CGEvent) {
        guard let copy = sep.copy() else { _ = core.resolve(job, nil); return }
        heldDowns.insert(sep.getIntegerValueField(.keyboardEventKeycode))
        note("hold \(job.id) \"\(job.typed)\" sep=\(job.sep.debugDescription) app=\(frontApp ?? "?")")
        held = (job, copy, frontApp)
        state = .holding(job.id)
        let id = job.id
        engine.correct(job, precheck: { Self.focusedFieldOK() }) { [weak self] r in
            self?.injectQ.async { self?.resolve(id, r) }
        }
        injectQ.asyncAfter(deadline: .now() + .milliseconds(settings.holdMs)) { [weak self] in self?.resolve(id, nil) }
    }

    /// injectQ: the held word end resolved (r == nil: too slow, skipped or failed)
    private func resolve(_ id: Int, _ r: WordResult?) {
        lock.lock()
        guard case .holding(let hid) = state, hid == id, let h = held else { lock.unlock(); return }
        held = nil
        // the user switched apps meanwhile: never type into another app
        let r2 = h.app == frontApp ? r : nil
        var evs: [CGEvent] = []
        let inj = core.resolve(h.job, r2)
        if let inj = inj {
            evs = synth(inj)
            corrections += 1
        }
        note("resolve \(id) " + (r == nil ? "timeout/skip" : r2 == nil ? "app changed" : "out=\"\(r!.out)\"")
             + (inj.map { " del=\($0.deletes) ins=\($0.text.debugDescription)" } ?? " no edit") + " queued=\(queue.count)")
        evs.append(fresh(h.sep))
        state = .injecting(tagAll(evs))
        lock.unlock()
        post(evs)
    }

    /// injectQ: our last event came back through the tap: replay what was queued meanwhile
    private func echoed(_ s: Int64) {
        lock.lock()
        guard case .injecting(let a) = state, a == s else { lock.unlock(); return }
        var out: [CGEvent] = []
        var startJob: CorrectionJob? = nil
        var startSep: CGEvent? = nil
        var undoEvents: [CGEvent] = []
        var undone: Undone? = nil
        while !queue.isEmpty {
            let e = queue.removeFirst()
            let d = process(e.type, e)
            if case .pass = d { out.append(fresh(e)); continue }
            if case .hold(let job) = d { startJob = job; startSep = e }
            if case .undo(let inj, let u) = d { undoEvents = synth(inj); undone = u; note("undo del=\(inj.deletes) ins=\(inj.text.debugDescription)") }
            break
        }
        if let job = startJob, let sep = startSep {
            _ = tagAll(out)
            beginHold(job, sep)
            lock.unlock()
            post(out)
            return
        }
        let evs = out + undoEvents
        if evs.isEmpty { state = .idle; heldDowns.removeAll(); lock.unlock(); if let u = undone { learn(u) }; return }
        state = .injecting(tagAll(evs))
        lock.unlock()
        post(evs)
        if let u = undone { learn(u) }
    }

    // MARK: synthesis

    /// lock held: tag events with increasing sequence numbers; -> the last one
    private func tagAll(_ evs: [CGEvent]) -> Int64 {
        for e in evs {
            seq = (seq + 1) & 0xffff_ffff
            e.setIntegerValueField(.eventSourceUserData, value: Self.MAGIC | seq)
        }
        return seq
    }

    /// lock held
    private func synth(_ inj: Injection) -> [CGEvent] {
        var evs: [CGEvent] = []
        for _ in 0..<inj.deletes { evs += key(CGKeyCode(kVK_Delete), nil) }
        for ch in inj.text {
            let code = layout.keyCodes[Character(ch.lowercased())] ?? (ch == " " ? CGKeyCode(kVK_Space) : 0)
            evs += key(code, String(ch))
        }
        return evs
    }

    /// lock held: a replayed real key as a brand-new event from our source (fresh timestamp); mouse events as copies
    private func fresh(_ e: CGEvent) -> CGEvent {
        guard e.type == .keyDown || e.type == .keyUp,
              let n = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(e.getIntegerValueField(.keyboardEventKeycode)),
                              keyDown: e.type == .keyDown) else { return e }
        n.flags = e.flags
        var len = 0
        var buf = [UniChar](repeating: 0, count: 8)
        e.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &len, unicodeString: &buf)
        if len > 0 { n.keyboardSetUnicodeString(stringLength: len, unicodeString: &buf) }
        n.setIntegerValueField(.keyboardEventAutorepeat, value: e.getIntegerValueField(.keyboardEventAutorepeat))
        n.setIntegerValueField(.keyboardEventKeyboardType, value: e.getIntegerValueField(.keyboardEventKeyboardType))
        return n
    }

    private func key(_ code: CGKeyCode, _ text: String?) -> [CGEvent] {
        var out: [CGEvent] = []
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            e.flags = []
            if let t = text {
                var u = Array(t.utf16)
                e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
            }
            out.append(e)
        }
        return out
    }

    /// injectQ: post in order; the watchdog finishes the batch if its echo never comes back (tap disabled, ...)
    private func post(_ evs: [CGEvent]) {
        // paced: Chromium/Electron apps (Discord, Slack, Chrome) reorder edits posted back to back
        var prevDelete = false
        for e in evs {
            let isDelete = e.type == .keyDown && e.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Delete)
            if prevDelete && !isDelete && e.type == .keyDown { usleep(6000) }
            if e.type == .keyDown { prevDelete = isDelete }
            e.post(tap: .cghidEventTap)
            usleep(2000)
        }
        if let last = evs.last {
            let s = last.getIntegerValueField(.eventSourceUserData) & 0xffff_ffff
            injectQ.asyncAfter(deadline: .now() + .milliseconds(600)) { [weak self] in self?.echoed(s) }
        }
    }

    // MARK: debug log

    /// lock held
    private func note(_ s: String) {
        debug.append(String(format: "%8.3f ", Date().timeIntervalSince(t0)) + s)
        if debug.count > 300 { debug.removeFirst(debug.count - 300) }
    }

    var debugLog: String {
        lock.lock(); defer { lock.unlock() }
        return "Autocorrect \(Updater.currentVersion), keyboard \(layout.name), holdMs \(settings.holdMs)\n" + debug.joined(separator: "\n")
    }

    // MARK: learning

    /// An undone correction: a spelling fix of a word the lexicon doesn't know -> personal dictionary ("not a typo");
    /// anything else (real-word swaps, capitals, merges) -> that edit is suppressed for a week.
    private func learn(_ u: Undone) {
        let typed = u.typed, out = u.out
        guard typed != out else { return }
        engine.queue.async { [engine] in
            let spelling = !typed.contains(" ") && !out.contains(" ") &&
                typed.lowercased().filter { $0.isLetter } != out.lowercased().filter { $0.isLetter }
            if spelling && !engine.inLexiconOnQueue(typed) { engine.user.add(typed) } else { engine.user.suppress(typed, out) }
        }
    }

    // MARK: focused field

    /// engine queue: skip password fields and fields with a selection (inline autocomplete in address bars)
    static func focusedFieldOK() -> Bool {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.05)
        var f: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &f) == .success, let fv = f,
              CFGetTypeID(fv) == AXUIElementGetTypeID() else { return true }
        let el = fv as! AXUIElement
        AXUIElementSetMessagingTimeout(el, 0.05)
        var sub: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &sub) == .success, let s = sub as? String,
           s == (kAXSecureTextFieldSubrole as String) { return false }
        var rng: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rng) == .success, let rv = rng,
           CFGetTypeID(rv) == AXValueGetTypeID() {
            var r = CFRange()
            if AXValueGetValue(rv as! AXValue, .cfRange, &r), r.length > 0 { return false }
        }
        return true
    }
}
