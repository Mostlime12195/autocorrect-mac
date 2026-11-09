import AppKit
import Carbon
import ApplicationServices
import Engine
import KeylimeCore
import os

/// The Accessibility text layer. The event tap only says *when* (keys, word ends, pauses); this reads the focused field,
/// asks the corrector, writes corrections in place (one atomic AX edit, keys held back meanwhile), and keeps the
/// overlay (underlines, the replace pill, the preview bubble, the suggestion popover) on the field's text.
///
/// Three stages:
///  (a) typing: optionally, after a short pause in a word, a bubble with the correction it's about to get
///  (b) word end: confident fixes are applied (auto mode); flagged-but-unsure words are underlined
///  (c) ~1 s idle: the sentences around the caret are re-checked with left and right context; flagged words are
///      underlined, and only confident spelling fixes in the current sentence are applied (auto mode). Never while typing.
final class TextLayer {
    private let engine: EngineHost
    private let input: InputController
    private let overlay: Overlay
    private let settings = Settings.shared
    let q = DispatchQueue(label: "kl.text", qos: .userInitiated)

    static let IDLE_SECS = 1.0
    static let PREVIEW_SECS = 0.25
    /// a correction can be reverted by clicking it for this long
    static let REVERT_SECS = 4.0
    static let IDLE_CHARS = 2000
    static let IDLE_LEFT = 200
    static let IDLE_SENTENCES = 6
    /// a mark whose word can't be found survives this long (apps re-rendering report stale / empty text)
    static let MARK_GRACE = 0.8

    // MARK: shared with the tap thread (lock)

    private let lock = NSLock()
    private var keySeq = 0
    /// keySeq at which backspace undoes the last correction
    private var undoArmed: Int?
    private var pillHits: [(rect: CGRect, until: Date, id: Int)] = []
    private var markHits: [(rect: CGRect, id: Int)] = []
    private var popoverRect: CGRect?
    private var previewShown = false
    private var frontPid: pid_t = 0
    /// when the last real key was seen (writes wait for the keys before them to land)
    private var lastKeyAt = Date.distantPast
    // diagnostics (status window / Copy Diagnostics)
    private var dPath = "unknown"
    private var dWhy = "nothing focused yet"
    private var dRole = "?"
    private var dApp = "?"
    private var dWord = "none yet"
    private var dIdle = "none yet"
    private var dWrite = "none yet"
    private var dDrawn = "nothing"
    private var dMarks = 0
    private var dFocus = "no queries yet"
    private var dBounds = "no marks queried yet"
    private var dPids = "no field yet"
    private var dTest = "not run"
    private var dClick = "none yet"
    private var parked: (el: AXUIElement, marks: [Mark])?
    private var readFailSince: Date?
    /// apps whose fields take a selection but not AX text writes: fixes are typed over the selection straight away
    private var typedApps = Set(UserDefaults.standard.stringArray(forKey: "typedWriteApps") ?? [])
    private var rectCache: [Int: (rect: CGRect, start: Int, frame: CGRect?)] = [:]
    private var dParams = "?"
    private var dSource = "none yet"
    private var dWritePath = "none yet"
    private var dPick = "none yet"
    private var wordsSincePass = 0
    let meter = PerfMeter()
    private var cpuTimer: DispatchSourceTimer?
    private var paramsFor: AXField?
    private let log = Logger(subsystem: "dev.mostlime.autocorrect-mac", category: "text")

    // MARK: text queue only

    private struct PrevInfo {
        let slot: Slot; let idx: Int; let out: String; let typed: String; let lmScored: Bool; let margin: Double
        let scores: [Double]?; let start: Int
    }
    /// an applied correction: revertable by its pill (and backspace, for the last one)
    private struct Recent {
        var start: Int; let newText: String; let oldText: String; let word: String; let learnTyped: String; let out: String
        let sep: String; let pillId: Int; let until: Date
    }
    private struct Pill { let id: Int; var range: NSRange; let text: String; let until: Date }
    private struct Preview { let start: Int; let word: String; let out: String }

    private var field: AXField?
    private var mode = InputController.FieldMode.unknown
    private let tracker = MarkTracker()
    private var prev: PrevInfo?
    private var recents: [Recent] = []
    private var pills: [Pill] = []
    private var nextPill = 1
    private var keepOnce: (start: Int, word: String)?
    /// "Ignore" this session
    private var ignored = Set<String>()
    private var sentenceCache: [String: [(SentenceFix, Bool)]] = [:]
    private var cacheOrder: [String] = []
    private var idleWork: DispatchWorkItem?
    private var previewWork: DispatchWorkItem?
    private var preview: Preview?
    private var popoverMark: Int?
    private var refreshPending = false
    private var timer: DispatchSourceTimer?
    private var observer: AXObserver?
    private var enabledPids = Set<pid_t>()
    /// elements whose AX writes didn't take (twice): keystroke fallback there for a minute
    private var noWrite: [(el: AXUIElement, fails: Int, at: Date)] = []
    private var lastProbe = Date.distantPast
    private var overlayEmpty = true

    init(engine: EngineHost, input: InputController, overlay: Overlay) {
        self.engine = engine; self.input = input; self.overlay = overlay
        overlay.onPopoverFrame = { [weak self] r in
            guard let self = self else { return }
            self.lock.lock(); self.popoverRect = r; self.lock.unlock()
        }
        let app = NSWorkspace.shared.frontmostApplication
        frontPid = app?.processIdentifier ?? 0
        if let a = app { appActivated(a) }
    }

    private var seqNow: Int { lock.lock(); defer { lock.unlock() }; return keySeq }

    // MARK: signals (tap thread / main)

    /// tap thread, input lock held: one key, in order. Must stay cheap.
    func signal(_ s: KeySignal, click: CGPoint? = nil) {
        lock.lock()
        keySeq += 1
        let seq = keySeq
        undoArmed = nil
        lastKeyAt = Date()
        let inPopover = click.map { popoverRect?.contains($0) ?? false } ?? false
        lock.unlock()
        if inPopover { return }
        q.async { self.onKey(s, seq: seq, click: click) }
    }

    /// tap thread: a click on a revert pill
    func interceptClick(_ p: CGPoint) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        guard let h = pillHits.first(where: { $0.until > now && $0.rect.insetBy(dx: -3, dy: -2).contains(p) }) else { return false }
        pillHits.removeAll { $0.id == h.id }
        keySeq += 1
        undoArmed = nil
        q.async { self.revert(pillId: h.id, viaBackspace: false) }
        return true
    }

    /// tap thread: Esc while the preview bubble is up cancels that correction
    func interceptEscape() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard previewShown else { return false }
        previewShown = false
        keySeq += 1
        q.async {
            if let p = self.preview { self.keepOnce = (p.start, p.word) }
            self.hidePreview()
        }
        return true
    }

    /// tap thread: backspace right after a correction undoes it
    func interceptBackspace() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let s = undoArmed, s == keySeq else { return false }
        undoArmed = nil
        keySeq += 1
        q.async {
            guard let last = self.recents.last else { self.input.postBackspace(); return }
            self.revert(pillId: last.pillId, viaBackspace: true)
        }
        return true
    }

    /// tap thread
    func scrolled() { q.async { self.rectCache.removeAll(); self.scheduleRefresh(after: 0.06) } }

    /// main
    func appActivated(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        let bid = app.bundleIdentifier
        lock.lock(); frontPid = pid; lock.unlock()
        // our own windows (Status, Settings): keep what we know about the app being typed in, for the diagnostics
        if pid == ProcessInfo.processInfo.processIdentifier { q.async { self.ownWindow() }; return }
        q.async {
            self.ownFront = false
            self.lock.lock(); self.dApp = bid ?? "pid \(pid)"; self.lock.unlock()
            // every activation, and only once we're trusted (before that the call does nothing, and an app activated
            // then would never build its tree)
            if AXIsProcessTrusted() {
                AXField.enableAccessibility(pid: pid, bundleId: bid)
                self.enabledPids.insert(pid)
            }
            if let f = self.field, self.owned(f, by: pid) {
                // back from one of our windows (or a menu): same field, same marks
                self.updateMode(f)
                self.pushOverlay()
            } else {
                self.switchField(nil)
                self.setMode(.unknown, "app switched, looking at the focused field")
            }
            // Electron builds its tree a moment after AXManualAccessibility: look again a little later
            self.q.asyncAfter(deadline: .now() + 0.3) { self.probe(force: true) }
            self.q.asyncAfter(deadline: .now() + 1.2) { if self.mode != .ax { self.probe(force: true) } }
        }
    }

    /// main: an AX notification from the focused app
    func axNotified(_ name: String) {
        q.async {
            if name == (kAXFocusedUIElementChangedNotification as String) {
                self.probe(force: true)
            } else {
                self.scheduleRefresh(after: 0.03)
            }
        }
    }

    // MARK: keys

    private func onKey(_ s: KeySignal, seq: Int, click: CGPoint?) {
        hidePreview()
        switch s {
        case .boundary(let w, let sep):
            closePopover()
            boundary(w, sep, seq)
        case .char:
            closePopover()
            schedulePreview(seq)
        case .reset:
            if let p = click {
                clicked(p)
                q.asyncAfter(deadline: .now() + 0.06) { self.probe(force: true) }
            } else {
                closePopover()
            }
        case .backspace, .other:
            closePopover()
        }
        if mode != .ax && click == nil { probe(force: false) }
        // fixes waiting for a safe moment: right after a separator, or after a pause
        if case .boundary = s { schedulePending(after: 0.06) } else { schedulePending(after: 0.6) }
        scheduleIdle(seq)
        scheduleRefresh(after: 0.05)
    }

    private func clicked(_ p: CGPoint) {
        lock.lock()
        let hits = markHits
        let hit = hits.last { $0.rect.insetBy(dx: -1, dy: -3).contains(p) }
        lock.unlock()
        closePopover()
        let near = hits.min { Self.dist($0.rect, p) < Self.dist($1.rect, p) }
        let at = "(\(Int(p.x)), \(Int(p.y)))"
        if let h = hit {
            noteClick("\(at) hit a mark at \(NSStringFromRect(h.rect)); opening fixes")
            // after the click has put the caret there; placed from the rect that was drawn (re-asking for bounds can
            // fail once the caret is inside the word)
            q.asyncAfter(deadline: .now() + 0.1) { self.showPopover(h.id, at: h.rect) }
        } else if let n = near {
            noteClick("\(at) missed; nearest of \(hits.count) mark(s) at \(NSStringFromRect(n.rect)), \(Int(Self.dist(n.rect, p))) pt away")
        } else {
            noteClick("\(at) missed; no marks drawn")
        }
    }

    private static func dist(_ r: CGRect, _ p: CGPoint) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    private func noteClick(_ s: String) {
        let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        lock.lock(); dClick = "\(t): \(s)"; lock.unlock()
        log.info("click: \(s, privacy: .public)")
        input.debugNote("click: " + s)
    }

    /// marks went away: say why in the recent events
    private func noteDropped(_ n: Int, _ why: String) {
        guard n > 0 else { return }
        input.debugNote("marks: \(n) removed (\(why))")
        log.info("\(n) mark(s) removed: \(why, privacy: .public)")
    }

    // MARK: field

    /// look at the focused element again (force: even if we looked very recently)
    /// Look at the focused element again (force: even if we looked very recently). A failed focus query keeps the
    /// field we have while it still answers (Electron flaps between the field and "no value"); see FocusTracker.
    private func probe(force: Bool) {
        if !force && Date().timeIntervalSince(lastProbe) < 1 { return }
        lastProbe = Date()
        lock.lock(); let front = frontPid; let bid = dApp; lock.unlock()
        var (f, why) = AXField.focused(app: front)
        if f == nil && field == nil && Date().timeIntervalSince(lastDiscover) > 2 {
            lastDiscover = Date()
            if let d = AXField.discover(app: front, bundleId: bid) { f = d; log.notice("focus discovery found the field") }
        }
        if f?.pid == ProcessInfo.processInfo.processIdentifier { ownWindow(); return }
        if f == nil { lastFocusWhy = why }
        let d = focus.observe(f?.el, now: Date().timeIntervalSince1970, alive: { AXField($0).liveness() })
        switch d {
        case .same: if let cur = field { updateMode(cur) } else { switchField(f) }
        case .changed: switchField(f)
        case .holding:
            if let cur = field { updateMode(cur) }
            if focus.failuresInRow == 1 { log.info("focus query failed (\(why, privacy: .public)); keeping the field") }
        case .lost, .none:
            if field != nil { log.notice("field lost: \(why, privacy: .public)") }
            switchField(nil)
        }
        let age = focus.lastGood.map { String(format: "%.1f s ago", Date().timeIntervalSince1970 - $0) } ?? "never"
        lock.lock()
        dFocus = "\(focus.failuresInRow) failed in a row, \(focus.failures) in total; last good \(age); last: \(d)" +
            (f == nil ? " (\(why))" : "")
        lock.unlock()
    }
    private var lastFocusWhy = ""
    /// a Keylime window (Status, Settings) is in front: nothing happens, the diagnostics keep the app's state
    private var ownFront = false
    private var bundleCache: [pid_t: String] = [:]

    private func bundle(_ pid: pid_t) -> String {
        if let b = bundleCache[pid] { return b }
        let b = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "?"
        if bundleCache.count > 64 { bundleCache.removeAll() }
        bundleCache[pid] = b
        return b
    }

    /// the field belongs to that app: same process, or one of its helpers (com.x.App.helper ...)
    private func owned(_ f: AXField, by pid: pid_t) -> Bool {
        if f.pid == pid { return true }
        let a = bundle(f.pid), b = bundle(pid)
        return a != "?" && b != "?" && (a.hasPrefix(b) || b.hasPrefix(a))
    }
    private lazy var focus = FocusTracker<AXUIElement>(grace: 3, same: { CFEqual($0, $1) })
    private var lastDiscover = Date.distantPast

    /// typing in Keylime's own windows: nothing happens there (and the diagnostics keep the last app)
    private func ownWindow() {
        ownFront = true
        if mode != .unknown { mode = .unknown; input.setFieldMode(.unknown) }
        hidePreview(); closePopover()
        DispatchQueue.main.async { self.overlay.show([]) }
        lock.lock(); markHits = []; pillHits = []; lock.unlock()
        overlayEmpty = true
    }

    private func setMode(_ m: InputController.FieldMode, _ why: String) {
        let name: String
        switch m { case .ax: name = "accessibility"; case .keys: name = "keystroke fallback"; case .unknown: name = "unknown" }
        lock.lock()
        let changed = dPath != name || dWhy != why
        dPath = name; dWhy = why
        let app = dApp
        lock.unlock()
        if changed { log.notice("path: \(name, privacy: .public) (\(why, privacy: .public)) app \(app, privacy: .public)") }
        if m != mode { mode = m; input.setFieldMode(m) }
    }

    /// nil: no focused element we can see (0.1 behaviour: keystroke fallback)
    private func updateMode(_ f: AXField?) {
        guard let f = f else {
            lock.lock(); dRole = "none"; lock.unlock()
            setMode(.keys, lastFocusWhy.isEmpty ? "no focused element" : lastFocusWhy)
            return
        }
        let role = (f.role ?? "?") + (f.subrole.map { "/" + $0 } ?? "")
        if !f.same(paramsFor) {
            paramsFor = f
            let names = f.parameterizedNames
            let p = names.isEmpty ? "none" : names.joined(separator: ", ")
            lock.lock(); dParams = p; lock.unlock()
            log.info("field \(role, privacy: .public) parameterized attributes: \(p, privacy: .public)")
        }
        lock.lock(); dRole = role; lock.unlock()
        noWrite.removeAll { Date().timeIntervalSince($0.at) > 60 }
        if f.isSecure { setMode(.ax, "password field: nothing happens here"); return }
        if let n = noWrite.first(where: { CFEqual($0.el, f.el) }), n.fails >= 2 {
            setMode(.keys, "accessibility writes failed here twice (\(f.lastWrite)); retrying in a minute"); return
        }
        if let why = f.whyNotReadable() {
            // a field that was readable a moment ago: one failed read (the app re-rendering) isn't a reason to switch
            // to typed keystrokes; 3 s of failures is
            if mode == .ax, f.same(field) {
                let since = readFailSince ?? Date()
                readFailSince = since
                if Date().timeIntervalSince(since) < 3 { return }
            }
            readFailSince = nil
            setMode(.keys, "\(role): \(why)")
            return
        }
        readFailSince = nil
        setMode(.ax, "\(role): text readable")
    }

    private func switchField(_ f: AXField?) {
        if f == nil { focus.reset() }
        if field == nil && f == nil { updateMode(nil); return }
        lock.lock(); dMarks = 0; lock.unlock()
        // set the marks aside: if this same field comes back (focus flaps, a quick app switch) they come back with it
        if let old = field, !tracker.isEmpty {
            parked = (old.el, tracker.marks)
            noteDropped(tracker.marks.count, (f == nil ? "field lost or app switched" : "focus moved to another field") + "; parked, back if the field returns")
        }
        tracker.removeAll(); pills.removeAll(); recents.removeAll(); prev = nil; keepOnce = nil; rectCache.removeAll()
        if let f = f, let p = parked, CFEqual(p.el, f.el) {
            tracker.restore(p.marks)
            parked = nil
            input.debugNote("marks: \(p.marks.count) restored (the field came back)")
        }
        hidePreview(); closePopover()
        field = f
        updateMode(f)
        observe(f)
        pushOverlay()
    }

    private func observe(_ f: AXField?) {
        if let o = observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .commonModes) }
        observer = nil
        guard let f = f else { return }
        var o: AXObserver?
        guard AXObserverCreate(f.pid, axCallback, &o) == .success, let obs = o else { return }
        let me = Unmanaged.passUnretained(self).toOpaque()
        _ = AXObserverAddNotification(obs, f.el, kAXValueChangedNotification as CFString, me)
        _ = AXObserverAddNotification(obs, f.el, kAXSelectedTextChangedNotification as CFString, me)
        if let w = f.window {
            _ = AXObserverAddNotification(obs, w, kAXMovedNotification as CFString, me)
            _ = AXObserverAddNotification(obs, w, kAXResizedNotification as CFString, me)
        }
        let app = AXUIElementCreateApplication(f.pid)
        AXUIElementSetMessagingTimeout(app, AXField.timeout)
        _ = AXObserverAddNotification(obs, app, kAXFocusedUIElementChangedNotification as CFString, me)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observer = obs
    }

    private func allowed() -> Bool {
        settings.mode != .off && engine.ready && !input.isInputMethod && !settings.isExcluded(input.frontmostBundleId)
            && !IsSecureEventInputEnabled()
    }

    /// the field when corrections can happen in it
    private func usableField() -> AXField? {
        guard allowed(), mode == .ax, let f = field, !f.isSecure else { return nil }
        return f
    }

    /// the whole-word occurrence of `word` closest before the caret (its separator may not have landed yet, and a few
    /// more keys may have)
    private func locate(_ word: String, _ s: AXField.Snapshot) -> Int? {
        let w = Array(word.utf16)
        let caret = s.caret - s.base
        var i = caret - w.count
        let lowest = max(0, caret - w.count - 24)
        while i >= lowest {
            if wholeWord(w, s, i) { return s.base + i }
            i -= 1
        }
        return nil
    }

    private func wholeWord(_ w: [UInt16], _ s: AXField.Snapshot, _ i: Int) -> Bool {
        guard i >= 0, i + w.count <= s.ns.length else { return false }
        for k in 0..<w.count where s.ns.character(at: i + k) != w[k] { return false }
        if i > 0 && MarkTracker.isWordUnit(s.ns.character(at: i - 1)) { return false }
        if i + w.count < s.ns.length && MarkTracker.isWordUnit(s.ns.character(at: i + w.count)) { return false }
        return true
    }

    /// text before an absolute offset (at most n UTF-16 units)
    private func textBefore(_ s: AXField.Snapshot, _ at: Int, _ n: Int) -> String {
        let a = max(s.base, at - n)
        return s.sub(NSRange(location: a, length: at - a)) ?? ""
    }

    /// the model's left context for text before `at`: as many characters as the context-length setting needs, from a
    /// start that only moves every 1024 characters (so the scorer's state cache keeps extending the same prefix)
    private func leftText(_ s: AXField.Snapshot, _ at: Int) -> String {
        let a = max(s.base, TypingCore.contextStart(at, chars: settings.perf.leftChars))
        return s.sub(NSRange(location: a, length: at - a)) ?? ""
    }

    private func charBefore(_ s: AXField.Snapshot, _ at: Int) -> Character? {
        guard at > s.base, let u = s.unit(at - 1), let sc = Unicode.Scalar(u) else { return nil }
        return Character(sc)
    }

    // MARK: (b) word end

    private func boundary(_ word: String, _ sep: String, _ seq: Int) {
        if field == nil || mode == .unknown { probe(force: true) }
        guard TypingCore.correctable(word) else { prev = nil; return }
        guard let f = usableField() else { prev = nil; noteWord("skipped: \(notUsableWhy())"); return }
        guard var snap = f.snapshot(), snap.selLength == 0 else { prev = nil; noteWord("skipped: field text unreadable or a selection"); return }
        var found = locate(word, snap)
        // Chromium / Electron update their accessibility text a little after the key
        for _ in 0..<5 where found == nil {
            usleep(40_000)
            guard let s2 = f.snapshot(), s2.selLength == 0 else { break }
            snap = s2
            found = locate(word, s2)
        }
        guard let start = found else { prev = nil; noteWord("skipped: the word isn't in the field text before the caret"); return }
        if let k = keepOnce, k.start == start, k.word == word { keepOnce = nil; prev = nil; return }
        guard start == 0 || TypingCore.isOpener(charBefore(snap, start)) else {
            prev = nil; noteWord("skipped: the word follows \(charBefore(snap, start).map { "U+" + String($0.unicodeScalars.first!.value, radix: 16, uppercase: true) } ?? "?"), not a space"); return
        }
        let (left, sp) = TypingCore.splitLeft(leftText(snap, start))
        let input = WordInput(typed: word, left: left, sep: sp)
        var pw: PrevWord? = nil
        var merge: MergeInput? = nil
        var used: PrevInfo? = nil
        if let p = prev, !sp.contains("\n"), p.start + p.out.utf16.count + sp.utf16.count == start, left.hasSuffix(p.out),
           snap.sub(NSRange(location: p.start, length: p.out.utf16.count)) == p.out {
            let (lp, sepp) = TypingCore.splitLeft(leftText(snap, p.start))
            pw = PrevWord(slot: p.slot, idx: p.idx, left: lp, sep: sepp, lmScored: p.lmScored, margin: p.margin, scores: p.scores)
            merge = MergeInput(prevTyped: p.typed)
            used = p
        }
        prev = nil
        let nameLike = Policy.nameLike(word, left: left)
        engine.correctWord(input, prev: pw, merge: merge) { [weak self] r, inLex in
            self?.q.async { self?.resolved(f, word, sep, start, seq, r, inLex, used, nameLike) }
        }
        // Performance: also re-check the sentence every N words (queued after this word's own correction)
        let n = settings.perf.everyWords
        if n > 0 {
            wordsSincePass += 1
            if wordsSincePass >= n { wordsSincePass = 0; q.async { self.idle(seq, typing: true) } }
        }
    }

    private func resolved(_ f: AXField, _ word: String, _ sep: String, _ start: Int, _ seq: Int, _ r: WordResult?, _ inLex: Bool,
                          _ used: PrevInfo?, _ nameLike: Bool) {
        guard let r = r, f.same(field), usableField() != nil else { return }
        meter.record(.wordEnd, ms: r.ms, at: Date().timeIntervalSince1970)
        let o = WordOutcome(r, typedOOV: !inLex)
        let userWord = engine.user.has(word) || ignored.contains(word.lowercased())
        let d = Policy.boundary(o, mode: settings.mode, hasPrev: used != nil, prevOut: used?.out, userWord: userWord,
                                penalty: { [engine] a, b in engine.user.penalty(a, b) }, nameLike: nameLike)
        func setPrev(_ out: String, _ at: Int) {
            if sep == "\n" { prev = nil; return }
            prev = PrevInfo(slot: r.slot, idx: r.chosen, out: out, typed: word, lmScored: r.lmScored, margin: r.lmScored ? r.margin : 0,
                            scores: r.lmScored ? r.scores : nil, start: at)
        }
        switch d {
        case .keep:
            noteWord(String(format: "kept (margin %.1f)", o.margin))
            setPrev(word, start)
        case .flag(let fixes, let spelling):
            prev = nil
            tracker.add(start: start, word: word, fixes: fixes, spelling: spelling)
            noteWord(String(format: "underlined, %d fixes (margin %.1f, gap %.1f)", fixes.count, o.margin, o.gap))
            pushOverlay()
        case .apply(let out, let prevNew, let merged):
            guard let snap = f.snapshot() else { return }
            var spanStart = start, oldText = word, newText = out
            if let p = used, merged || prevNew != nil {
                guard let mid = snap.sub(NSRange(location: p.start, length: start - p.start)), mid.hasPrefix(p.out) else { return }
                spanStart = p.start
                oldText = mid + word
                newText = merged ? out : prevNew! + String(mid.dropFirst(p.out.count)) + out
            }
            let range = NSRange(location: spanStart, length: (oldText as NSString).length)
            prev = nil
            let margin = o.margin
            // written when it's safe: never into the word being typed; mid-word it waits for the separator / a pause
            fix(PendingFix(f: f, range: range, old: oldText, new: newText, made: Date()) { [weak self] res, at in
                guard let self = self else { return }
                self.noteWord(String(format: "fixed (margin %.1f): write ", margin) + "\(res)" + (at != spanStart ? " (moved \(at - spanStart))" : ""))
                switch res {
                case .ok:
                    let newLen = (newText as NSString).length
                    self.edited(at: at, oldLen: range.length, newLen: newLen)
                    let pid = self.addPill(NSRange(location: at, length: newLen), newText)
                    self.recents.append(Recent(start: at, newText: newText, oldText: oldText, word: word, learnTyped: merged ? oldText : word,
                                               out: out, sep: sep, pillId: pid, until: Date().addingTimeInterval(Self.REVERT_SECS)))
                    if self.recents.count > 6 { self.recents.removeFirst() }
                    // backspace undoes it, and it's the previous word for the next one, while nothing else was typed
                    self.lock.lock(); let fresh = self.keySeq == seq; if fresh { self.undoArmed = seq }; self.lock.unlock()
                    if fresh && !merged { setPrev(out, at + newLen - (out as NSString).length) }
                    self.pushOverlay()
                case .unsupported:
                    self.writesFailed(f)
                case .changed:
                    break
                }
            })
        }
    }

    // MARK: writes

    /// A fix waiting to be written (see fix()).
    private struct PendingFix {
        let f: AXField
        let range: NSRange
        let old: String
        let new: String
        let made: Date
        let done: (AXField.Write, Int) -> Void
    }
    private var pendingFixes: [PendingFix] = []
    private var pendingWork: DispatchWorkItem?

    /// Write a fix now if it's safe, else keep it until the next separator or a pause (it's re-anchored every try).
    private func fix(_ p: PendingFix) {
        guard p.f.same(field), Date().timeIntervalSince(p.made) < 30 else { input.debugNote("fix dropped: the field changed or it waited too long"); return }
        let (res, at, why) = write(p.f, p.range, old: p.old, new: p.new)
        guard let r = res else {
            // tried again at the next separator or after a pause (onKey), not in a loop
            pendingFixes.append(p)
            input.debugNote("fix waits: \(why)")
            return
        }
        if r != .ok && !why.isEmpty { input.debugNote("fix not written: \(why)") }
        p.done(r, at)
    }

    private func schedulePending(after: Double) {
        guard !pendingFixes.isEmpty else { return }
        pendingWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let ps = self.pendingFixes
            self.pendingFixes = []
            for p in ps { self.fix(p) }
        }
        pendingWork = w
        q.asyncAfter(deadline: .now() + after, execute: w)
    }

    /// One write, anchored to the text, inside one hold of the user's keys: let the keys typed just before land,
    /// re-read the field, find the target by its content (never the word at the caret; while the user is mid-word,
    /// wait), write it, put the caret back where it was relative to the text, then replay the held keys in order.
    /// -> (nil = wait, try later), where it was written, why not
    private func write(_ f: AXField, _ r: NSRange, old: String, new: String, atCaretOK: Bool = false) -> (res: AXField.Write?, at: Int, why: String) {
        var res: AXField.Write? = nil
        var at = r.location
        var why = ""
        input.gate {
            self.settle(f)
            guard let snap = f.snapshot() else { why = "couldn't read the field"; res = .changed; return }
            if snap.selLength > 0 && !atCaretOK { why = "the user has text selected"; return }
            self.lock.lock(); let typing = Date().timeIntervalSince(self.lastKeyAt) < 0.45; self.lock.unlock()
            switch FixAnchor.check(text: snap.text, base: snap.base, caret: snap.caret, old: old, start: r.location, atCaretOK: atCaretOK,
                                   typing: typing) {
            case .wait(let w): why = w
            case .drop(let w): why = w; res = .changed
            case .apply(let a):
                at = a
                res = self.rawWrite(f, NSRange(location: a, length: r.length), old: old, new: new)
            }
        }
        return (res, at, why)
    }

    /// keys are held now: give the ones delivered just before a moment to land, until the caret stops moving
    private func settle(_ f: AXField) {
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 0.3 {
            lock.lock(); let last = lastKeyAt; lock.unlock()
            if Date().timeIntervalSince(last) >= 0.06 { break }
            usleep(10_000)
        }
        var s = f.selection
        for _ in 0..<5 {
            usleep(12_000)
            let s2 = f.selection
            if s2 == s { break }
            s = s2
        }
    }

    /// the write itself (keys already held): AX text write, or typing over the selection where that doesn't take
    private func rawWrite(_ f: AXField, _ r: NSRange, old: String, new: String) -> AXField.Write {
        var res = AXField.Write.changed
        let app = bundle(f.pid)
        if typedApps.contains(app) {
            // remembered: this app ignores AX text writes, so don't wait for one to time out
            res = f.replaceByTyping(r, old: old, new: new) { self.input.typeTagged($0) }
            if res == .ok { lock.lock(); dWritePath = "\(app): typing over the selection (remembered)"; lock.unlock() }
        } else {
            res = f.replace(r, old: old, new: new)
            if res == .ok { lock.lock(); dWritePath = "\(app): accessibility text write"; lock.unlock() }
            // editors that take a selection but ignore AXSelectedText (Slate in Discord): type over the selection
            if res == .unsupported && f.lastSelectionOK {
                let first = f.lastWrite
                res = f.replaceByTyping(r, old: old, new: new) { self.input.typeTagged($0) }
                f.lastWrite += " (AX write: \(first))"
                if res == .ok {
                    typedApps.insert(app)
                    UserDefaults.standard.set(Array(typedApps), forKey: "typedWriteApps")
                    lock.lock(); dWritePath = "\(app): typing over the selection (AX write didn't take; remembered)"; lock.unlock()
                    log.notice("\(app, privacy: .public): AX writes don't take, typing over the selection from now on")
                }
            }
        }
        lock.lock(); dWrite = "\(res): \(f.lastWrite)"; lock.unlock()
        if res != .ok { log.notice("write \(String(describing: res), privacy: .public): \(f.lastWrite, privacy: .public)") }
        return res
    }

    private func writesFailed(_ f: AXField) {
        log.error("accessibility write failed: \(f.lastWrite, privacy: .public)")
        if let i = noWrite.firstIndex(where: { CFEqual($0.el, f.el) }) {
            noWrite[i].fails += 1; noWrite[i].at = Date()
        } else {
            noWrite.append((f.el, 1, Date()))
        }
        if noWrite.count > 20 { noWrite.removeFirst() }
        updateMode(f)
    }

    private func notUsableWhy() -> String {
        if ownFront { return "a Keylime window is in front" }
        if settings.mode == .off { return "mode is Off" }
        if !engine.ready { return "model not ready" }
        if input.isInputMethod { return "an input method is active" }
        if settings.isExcluded(input.frontmostBundleId) { return "app is excluded/paused" }
        if IsSecureEventInputEnabled() { return "secure input is on" }
        if mode != .ax { lock.lock(); defer { lock.unlock() }; return "path is \(dPath): \(dWhy)" }
        if field?.isSecure == true { return "password field" }
        return "no field"
    }

    /// last end-of-word decision (no typed text in it)
    private func noteWord(_ s: String) {
        let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        lock.lock(); dWord = "\(t): \(s)"; lock.unlock()
        log.info("word end: \(s, privacy: .public)")
        input.debugNote("ax: word end: " + s)
    }

    private func noteIdle(_ s: String) {
        let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        lock.lock(); dIdle = "\(t): \(s)"; lock.unlock()
        log.info("pause: \(s, privacy: .public)")
    }

    /// the text changed by our own edit: marks, pills and revertable corrections after it move
    private func edited(at: Int, oldLen: Int, newLen: Int) {
        tracker.applyEdit(at: at, oldLen: oldLen, newLen: newLen)
        let d = newLen - oldLen
        pills = pills.compactMap { p in
            if NSMaxRange(p.range) <= at { return p }
            if p.range.location >= at + oldLen { var n = p; n.range.location += d; return n }
            return nil
        }
        recents = recents.compactMap { r in
            let end = r.start + (r.newText as NSString).length + (r.sep as NSString).length
            if end <= at { return r }
            if r.start >= at + oldLen { var n = r; n.start += d; return n }
            return nil
        }
        sentenceCacheTouched()
    }

    // MARK: revert

    private func revert(pillId: Int, viaBackspace: Bool) {
        guard let i = recents.lastIndex(where: { $0.pillId == pillId }), let f = field, let snap = f.snapshot() else {
            if viaBackspace { input.postBackspace() }
            return
        }
        let rc = recents.remove(at: i)
        // backspace: the correction and its separator go back to exactly what was typed; a click: just the word
        let old = rc.newText + (viaBackspace ? rc.sep : "")
        let range = NSRange(location: rc.start, length: (old as NSString).length)
        guard snap.sub(range) == old else { if viaBackspace { input.postBackspace() }; return }
        // an explicit undo may touch the word at the caret
        let (res, at, why) = write(f, range, old: old, new: rc.oldText, atCaretOK: true)
        input.debugNote("ax: revert \"\(old)\" -> \"\(rc.oldText)\" \(res.map { "\($0)" } ?? "waiting") \(why)")
        guard res == .ok else { if viaBackspace { input.postBackspace() }; return }
        let newLen = (rc.oldText as NSString).length
        edited(at: at, oldLen: range.length, newLen: newLen)
        pills.removeAll { $0.id == rc.pillId }
        keepOnce = (at + newLen - (rc.word as NSString).length, rc.word)
        prev = nil
        pushOverlay()
        // Learning waits a few seconds: an undo followed by retyping the same correction was an accident, not a
        // rejection. Otherwise, as backspace-undo on Android: the edit needs more evidence for a week (and a non-word
        // typed on purpose goes in the personal dictionary, unless it looks like a slip of a common word).
        let undoneAt = Date().timeIntervalSince1970
        let spot = at
        q.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self = self else { return }
            let now = self.wordAt(f, spot)
            if QualityGuard.accidentalUndo(undoneAt: undoneAt, now: Date().timeIntervalSince1970, wordNow: now, correction: rc.out, within: 5) {
                self.input.debugNote("undo looked accidental (the correction was typed again): nothing learned")
                return
            }
            self.engine.user.suppress(rc.learnTyped, rc.out)
            self.input.learn(Undone(typed: rc.learnTyped, out: rc.out))
        }
    }

    /// the whole word at (or touching) an offset in the field now
    private func wordAt(_ f: AXField, _ at: Int) -> String? {
        guard let s = f.snapshot(), at >= s.base, at <= s.end else { return nil }
        var a = at, b = at
        while a > s.base, let u = s.unit(a - 1), MarkTracker.isWordUnit(u) { a -= 1 }
        while let u = s.unit(b), MarkTracker.isWordUnit(u) { b += 1 }
        return b > a ? s.sub(NSRange(location: a, length: b - a)) : nil
    }

    // MARK: (a) preview while typing

    private func schedulePreview(_ seq: Int) {
        previewWork?.cancel()
        guard settings.preview, settings.mode == .auto else { return }
        let w = DispatchWorkItem { [weak self] in self?.computePreview(seq) }
        previewWork = w
        q.asyncAfter(deadline: .now() + Self.PREVIEW_SECS, execute: w)
    }

    private func computePreview(_ seq: Int) {
        guard seqNow == seq, let f = usableField(), let snap = f.snapshot(), snap.selLength == 0 else { return }
        // the word ending at the caret, nothing word-like right after it
        if let next = snap.unit(snap.caret), MarkTracker.isWordUnit(next) { return }
        var a = snap.caret
        while a > snap.base, let u = snap.unit(a - 1), MarkTracker.isWordUnit(u) { a -= 1 }
        guard a < snap.caret, let word = snap.sub(NSRange(location: a, length: snap.caret - a)), TypingCore.correctable(word),
              a == 0 || TypingCore.isOpener(charBefore(snap, a)) else { return }
        if engine.user.has(word) || ignored.contains(word.lowercased()) { return }
        let (left, sp) = TypingCore.splitLeft(leftText(snap, a))
        engine.correctWord(WordInput(typed: word, left: left, sep: sp), prev: nil, merge: nil) { [weak self] r, inLex in
            self?.q.async {
                guard let self = self, let r = r, self.seqNow == seq, f.same(self.field) else { return }
                let d = Policy.boundary(WordOutcome(r, typedOOV: !inLex), mode: .auto, hasPrev: false, prevOut: nil, userWord: false,
                                        penalty: { [engine = self.engine] x, y in engine.user.penalty(x, y) },
                                        nameLike: Policy.nameLike(word, left: left))
                guard case .apply(let out, nil, false) = d, out.lowercased() != word.lowercased(),
                      let rect = f.bounds(NSRange(location: a, length: (word as NSString).length)) else { return }
                self.preview = Preview(start: a, word: word, out: out)
                self.lock.lock(); self.previewShown = true; self.lock.unlock()
                DispatchQueue.main.async { self.overlay.showPreview(rect, out) }
            }
        }
    }

    private func hidePreview() {
        previewWork?.cancel()
        guard preview != nil else { return }
        preview = nil
        lock.lock(); previewShown = false; lock.unlock()
        DispatchQueue.main.async { self.overlay.hidePreview() }
    }

    // MARK: (c) idle pass

    private func scheduleIdle(_ seq: Int) {
        idleWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.idle(seq) }
        idleWork = w
        q.asyncAfter(deadline: .now() + settings.perf.idleSecs, execute: w)
    }

    /// typing: the every-N-words re-check (current sentence only, never writes; the next key cancels it)
    private func idle(_ seq: Int, typing: Bool = false) {
        guard seqNow == seq else { return }
        let perf = settings.perf
        guard let f = usableField() else { noteIdle("skipped: \(notUsableWhy())"); return }
        guard let snap = f.snapshot() else { noteIdle("skipped: couldn't read the field's text"); return }
        guard snap.selLength == 0 else { noteIdle("skipped: \(snap.selLength) characters are selected"); return }
        let caretRel = snap.caret - snap.base
        let lo = perf.wholeField && !typing ? 0 : max(0, caretRel - Self.IDLE_CHARS)
        let hi = perf.wholeField && !typing ? snap.ns.length : min(snap.ns.length, caretRel + Self.IDLE_CHARS)
        guard hi > lo else { return }
        let text = snap.ns.substring(with: NSRange(location: lo, length: hi - lo))
        let winBase = snap.base + lo
        let chars = Array(text)
        var offs: [Int] = []
        offs.reserveCapacity(chars.count + 1)
        var u = 0
        for c in chars { offs.append(u); u += c.utf16.count }
        offs.append(u)
        let caretChar = offs.firstIndex { $0 >= caretRel - lo } ?? chars.count
        var todo: [(range: Range<Int>, key: String, left: String, after: String)] = []
        let splits = SentenceCheck.split(text)
        for (k, r) in splits.enumerated() {
            let left = String(chars[max(0, r.lowerBound - perf.leftChars)..<r.lowerBound])
            // the next sentence (and the space before it), as right context for the words near this one's end
            let after = perf.nextSentence && k + 1 < splits.count ? String(chars[r.upperBound..<splits[k + 1].upperBound]) : ""
            let key = left + "\u{1}" + String(chars[r]) + "\u{2}" + after
            if sentenceCache[key] == nil { todo.append((r, key, left, after)) }
        }
        guard !todo.isEmpty else { noteIdle("nothing new to check"); return }
        // nearest to the caret first
        todo.sort { dist($0.range, caretChar) < dist($1.range, caretChar) }
        if typing {
            // only the sentence being typed (the one holding the caret, if it changed)
            todo = todo.filter { $0.range.lowerBound <= caretChar && caretChar <= $0.range.upperBound }
            guard !todo.isEmpty else { return }
        }
        let batch = perf.wholeField && !typing ? todo : Array(todo.prefix(typing ? 1 : Self.IDLE_SENTENCES))
        let reqs = batch.map { SentenceReq(left: $0.left, sentence: String(chars[$0.range]), after: $0.after) }
        let more = todo.count > batch.count
        let t0 = Date()
        engine.checkSentences(reqs, cancelled: { [weak self] in self?.seqNow != seq }) { [weak self] res in
            let ms = Date().timeIntervalSince(t0) * 1000
            if res == nil { self?.meter.cancelled(at: Date().timeIntervalSince1970) } else { self?.meter.record(.pass, ms: ms, at: Date().timeIntervalSince1970) }
            self?.q.async {
                guard let self = self else { return }
                guard let res = res, self.seqNow == seq, f.same(self.field), let s2 = f.snapshot(),
                      s2.base == snap.base, s2.caret == snap.caret, s2.text == snap.text else { self.noteIdle("dropped: typing resumed or the text changed"); return }
                self.noteIdle("\(typing ? "while typing: " : "")checked \(res.count) sentence(s) in \(Int(ms)) ms, \(res.reduce(0) { $0 + $1.count }) flagged")
                var applies: [(range: NSRange, from: String, to: String)] = []
                for (j, fixes) in res.enumerated() {
                    let b = batch[j]
                    self.cache(b.key, fixes)
                    let s0 = winBase + offs[b.range.lowerBound], s1 = winBase + offs[b.range.upperBound]
                    // only marks an earlier pause check made are taken back; word-end marks stay until their word changes
                    let before = self.tracker.marks.count
                    self.tracker.removeAll(in: s0..<s1, onlyIdle: true)
                    self.noteDropped(before - self.tracker.marks.count, "pause re-check no longer flags them")
                    let current = b.range.lowerBound <= caretChar && caretChar <= b.range.upperBound
                    for (fx, spelling) in fixes {
                        let a = winBase + offs[b.range.lowerBound + fx.start]
                        let len = (fx.from as NSString).length
                        let userWord = self.engine.user.has(fx.from) || self.ignored.contains(fx.from.lowercased())
                        switch Policy.idle(gap: fx.gap, spelling: spelling, mode: self.settings.mode,
                                           inCurrentSentence: current && a + len <= snap.caret, userWord: userWord) {
                        case .apply where !typing: applies.append((NSRange(location: a, length: len), fx.from, fx.to))
                        case .apply: fallthrough   // no text changes while typing: underline it instead
                        case .flag:
                            if !self.tracker.has(start: a, word: fx.from) {
                                self.tracker.add(start: a, word: fx.from, fixes: fx.fixes, spelling: spelling, fromIdle: true)
                            }
                        case .none: break
                        }
                    }
                }
                // writes last, right to left so earlier offsets hold, and only while the user still isn't typing
                for ap in applies.sorted(by: { $0.range.location > $1.range.location }) {
                    guard self.seqNow == seq else { break }
                    self.fix(PendingFix(f: f, range: ap.range, old: ap.from, new: ap.to, made: Date()) { [weak self] r, at in
                        guard let self = self else { return }
                        self.noteIdle("fixed a word after the pause: write \(r)")
                        if r == .unsupported { self.writesFailed(f); return }
                        guard r == .ok else { return }
                        let newLen = (ap.to as NSString).length
                        self.edited(at: at, oldLen: ap.range.length, newLen: newLen)
                        let pid = self.addPill(NSRange(location: at, length: newLen), ap.to)
                        self.recents.append(Recent(start: at, newText: ap.to, oldText: ap.from, word: ap.from, learnTyped: ap.from,
                                                   out: ap.to, sep: "", pillId: pid, until: Date().addingTimeInterval(Self.REVERT_SECS)))
                        self.pushOverlay()
                    })
                }
                self.pushOverlay()
                if more && !typing { self.scheduleIdle(seq) }
            }
        }
    }

    private func dist(_ r: Range<Int>, _ c: Int) -> Int { c < r.lowerBound ? r.lowerBound - c : (c > r.upperBound ? c - r.upperBound : 0) }

    private func cache(_ key: String, _ v: [(SentenceFix, Bool)]) {
        if sentenceCache[key] == nil { cacheOrder.append(key) }
        sentenceCache[key] = v
        if cacheOrder.count > 64 { sentenceCache.removeValue(forKey: cacheOrder.removeFirst()) }
    }

    /// after our own edits or a dictionary / ignore change: sentences get checked again
    private func sentenceCacheTouched() { sentenceCache.removeAll(); cacheOrder.removeAll() }

    // MARK: popover

    private func showPopover(_ id: Int, at rect: CGRect) {
        guard field != nil else { noteClick("popover not shown: no field any more"); return }
        guard let m = tracker.mark(id: id) else { noteClick("popover not shown: the mark was removed after the click"); return }
        guard !m.fixes.isEmpty else { noteClick("popover not shown: the mark has no fixes"); return }
        popoverMark = id
        noteClick("popover shown for a mark with \(m.fixes.count) fix(es)")
        let actions = PopoverActions(
            pick: { [weak self] s in self?.q.async { self?.notePick("chose a fix from the menu"); self?.applyFix(id, s) } },
            ignore: { [weak self] in self?.q.async { self?.ignore(id) } },
            add: { [weak self] in self?.q.async { self?.addToDictionary(id) } })
        DispatchQueue.main.async { self.overlay.showPopover(below: rect, word: m.word, fixes: m.fixes, actions: actions) }
    }

    private func closePopover() {
        guard popoverMark != nil else { return }
        popoverMark = nil
        DispatchQueue.main.async { self.overlay.closePopover() }
    }

    private func applyFix(_ id: Int, _ to: String) {
        closePopover()
        guard let f = field else { notePick("failed: no field any more"); return }
        guard let m = tracker.mark(id: id) else { notePick("failed: the mark was removed before the fix ran"); return }
        guard let snap = f.snapshot() else { notePick("failed: couldn't read the field's text"); return }
        // the mark's offset can be stale (parked and restored, text edited before it): find the word again
        guard let found = MarkTracker.locate(m, in: snap.text, base: snap.base) else {
            let there = snap.sub(NSRange(location: m.start, length: m.length)) ?? "nothing"
            notePick("failed: \"\(m.word)\" isn't in the field any more (reads \"\(there)\" there)")
            tracker.remove(id: id)
            pushOverlay()
            return
        }
        let range = NSRange(location: found, length: m.length)
        let t0 = Date()
        // the user chose it: the word at the caret is fair game (they clicked into it)
        let (res, wrote, why) = write(f, range, old: m.word, new: to, atCaretOK: true)
        let r = res ?? .changed
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        input.debugNote("ax: pick \"\(m.word)\" -> \"\(to)\" \(r)")
        if r == .unsupported { writesFailed(f) }
        guard r == .ok else { notePick("failed after \(ms) ms: write \(r): \(why.isEmpty ? f.lastWrite : why)"); return }
        let at = wrote
        notePick("fixed in \(ms) ms: \(f.lastWrite)" + (at != m.start ? " (the word had moved \(at - m.start) chars)" : ""))
        tracker.remove(id: id)
        let newLen = (to as NSString).length
        edited(at: at, oldLen: m.length, newLen: newLen)
        _ = addPill(NSRange(location: at, length: newLen), to, revertable: false)
        pushOverlay()
    }

    private func notePick(_ s: String) {
        let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        lock.lock(); dPick = "\(t): \(s)"; lock.unlock()
        log.notice("pick: \(s, privacy: .public)")
        input.debugNote("pick: " + s)
    }

    private func ignore(_ id: Int) {
        closePopover()
        guard let m = tracker.mark(id: id) else { return }
        ignored.insert(m.word.lowercased())
        tracker.removeAll(word: m.word)
        if let fix = m.fixes.first { engine.user.suppress(m.word, fix) }
        sentenceCacheTouched()
        pushOverlay()
    }

    private func addToDictionary(_ id: Int) {
        closePopover()
        guard let m = tracker.mark(id: id) else { return }
        engine.user.add(m.word)
        tracker.removeAll(word: m.word)
        sentenceCacheTouched()
        pushOverlay()
    }

    // MARK: usage meter

    /// CPU time every 5 s, for the meter's CPU %
    func startCpuSampling() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now(), repeating: 5)
        t.setEventHandler { [weak self] in
            var u = rusage()
            getrusage(RUSAGE_SELF, &u)
            let s = Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
            self?.meter.cpuSample(seconds: s, at: Date().timeIntervalSince1970)
        }
        t.resume()
        cpuTimer = t
    }

    /// any thread
    func usage() -> String {
        let p = settings.perf
        let s = meter.summary(now: Date().timeIntervalSince1970, pauseSecs: p.idleSecs, backlog: engine.pending)
        func st(_ x: PerfMeter.Stat) -> String { x.count == 0 ? "none" : String(format: "%d, avg %.0f ms, p95 %.0f ms", x.count, x.avgMs, x.p95Ms) }
        let cpu = s.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "measuring…"
        return [
            "Last minute: word ends \(st(s.wordEnds)); re-checks \(st(s.passes)); \(s.cancelled) re-check(s) cut short by typing",
            "Keylime CPU: \(cpu) of one core; energy: \(s.energy)",
            s.behind.map { "⚠️ Falling behind: \($0). Try a longer pause or a lighter preset." } ?? "Keeping up.",
        ].joined(separator: "\n")
    }

    // MARK: diagnostics

    /// any thread
    func diagnostics() -> String {
        let excluded = settings.isExcluded(input.frontmostBundleId)
        lock.lock(); defer { lock.unlock() }
        return [
            "Accessibility trusted: \(AXIsProcessTrusted() ? "yes" : "NO")",
            "Mode: \(settings.mode.rawValue), preview \(settings.preview ? "on" : "off")",
            "Frontmost app: \(dApp)\(excluded ? " (excluded/paused)" : "")",
            "Focused element: \(dRole)",
            "Path: \(dPath) (\(dWhy))",
            "Focus queries: \(dFocus)",
            "Last word end: \(dWord)",
            "Last pause check: \(dIdle)",
            "Last write: \(dWrite)",
            "Processes: \(dPids)",
            "Marks: \(dMarks); drawn: \(dDrawn)",
            "Bounds (last mark queried): \(dBounds)",
            "Bounds source in use: \(dSource)",
            "Field parameterized attributes: \(dParams)",
            "Test underline: \(dTest)",
            "Last click: \(dClick)",
            "Write path: \(dWritePath)",
            "Last pick: \(dPick)",
            "Performance: \(settings.perf.presetId), pause \(settings.perf.idleSecs) s, every \(settings.perf.everyWords) words, " +
                "\(settings.perf.wholeField ? "whole text box" : "near the caret"), context \(settings.perf.ctxTokens) tokens (\(engine.contextInfo)), next sentence \(settings.perf.nextSentence)",
        ].joined(separator: "\n")
    }

    /// "Show Test Underline": a mark under the text before the caret in the focused field, or at the mouse
    func showTestUnderline(mouse: CGPoint) {
        q.async {
            self.lock.lock(); let front = self.frontPid; self.lock.unlock()
            var rect: CGRect? = nil
            var why = ""
            // the field we're holding first (the focus query itself may be failing), else a fresh query
            var f = self.field
            var source = "held field"
            var fwhy = ""
            if f == nil || f?.selection == nil {
                let fresh = AXField.focused(app: front)
                f = fresh.field; fwhy = fresh.why; source = "fresh focus query"
            }
            if let f = f, let sel = f.selection {
                let a = max(0, sel.location - 5)
                let range = sel.location > a ? NSRange(location: a, length: sel.location - a) : NSRange(location: sel.location, length: 1)
                let (b, detail) = BoundsSession(f).bounds(range, all: true)
                rect = b
                why = b == nil ? "\(source): no bounds (\(detail)), drew at the mouse" : "\(source): under the text before the caret, \(detail)"
            } else {
                why = f == nil ? "\(fwhy): drew at the mouse" : "\(source) has no selection: drew at the mouse"
            }
            let r = rect ?? CGRect(x: mouse.x - 40, y: mouse.y - 10, width: 80, height: 18)
            self.log.notice("test underline: \(why, privacy: .public) at \(NSStringFromRect(r), privacy: .public)")
            self.lock.lock(); self.dTest = why; self.lock.unlock()
            DispatchQueue.main.async { self.overlay.showTest(r) }
        }
    }

    // MARK: overlay

    private func addPill(_ r: NSRange, _ text: String, revertable: Bool = true) -> Int {
        let id = nextPill
        nextPill += 1
        pills.append(Pill(id: id, range: r, text: text, until: Date().addingTimeInterval(revertable ? Self.REVERT_SECS : 0.7)))
        if pills.count > 8 { pills.removeFirst() }
        return id
    }

    private func scheduleRefresh(after: Double) {
        guard !refreshPending else { return }
        refreshPending = true
        q.asyncAfter(deadline: .now() + after) { [weak self] in
            self?.refreshPending = false
            self?.refresh()
        }
    }

    /// re-locate marks in the field's current text and re-query where they are on screen
    private func refresh() {
        let now = Date()
        if settings.mode == .off || settings.isExcluded(input.frontmostBundleId) {
            noteDropped(tracker.marks.count, "mode is Off or app paused")
            tracker.removeAll(); pills.removeAll(); recents.removeAll()
        }
        pills.removeAll { $0.until < now }
        let lastId = recents.last?.pillId
        recents.removeAll { $0.until < now && $0.pillId != lastId }
        if let f = field, !(tracker.isEmpty && pills.isEmpty), let snap = f.snapshot() {
            let gone = tracker.reconcile(snap.text, base: snap.base, now: now.timeIntervalSince1970, grace: Self.MARK_GRACE)
            noteDropped(gone.count, "word changed or gone from the text for \(Self.MARK_GRACE) s")
            for id in gone { rectCache[id] = nil }
            pills.removeAll { snap.sub($0.range) != $0.text }
        }
        pushOverlay()
    }

    private func pushOverlay() {
        let now = Date()
        lock.lock(); let front = frontPid; lock.unlock()
        var items: [Overlay.Item] = []
        var mh: [(rect: CGRect, id: Int)] = []
        var ph: [(rect: CGRect, until: Date, id: Int)] = []
        if ownFront {
            // our window is in front: draw nothing, but keep the last real state for the status window
            lock.lock(); markHits = []; pillHits = []; lock.unlock()
            if !overlayEmpty { overlayEmpty = true; DispatchQueue.main.async { self.overlay.show([]) } }
            stopTimer()
            return
        }
        var boundsNote: String? = nil
        var hidden = 0
        var cached = 0
        if let f = field, owned(f, by: front), mode == .ax, !(tracker.isEmpty && pills.isEmpty) {
            let visible = f.visibleFrame()
            let session = BoundsSession(f)
            var first = true
            let t0 = Date()
            for m in tracker.marks.suffix(40) {
                if Date().timeIntervalSince(t0) > 0.15 { break }   // a slow app: draw what we have
                // until some source has worked here, the first mark tries them all (the status window shows each)
                let (b, detail) = session.bounds(NSRange(location: m.start, length: m.length), all: first && f.boundsSource == nil)
                first = false
                boundsNote = detail
                // keep the last good rect while the text under it and the field's frame haven't changed (sources
                // like the caret only cover one line; apps re-render)
                var rr = b
                if let r = b {
                    rectCache[m.id] = (r, m.start, visible)
                } else if let c = rectCache[m.id], c.start == m.start, c.frame == visible {
                    rr = c.rect
                    cached += 1
                }
                guard let r = rr else { continue }
                if let v = visible, !v.intersects(r) { hidden += 1; continue }
                items.append(.mark(r, spelling: m.spelling, id: m.id))
                mh.append((r, m.id))
            }
            for p in pills where p.until > now {
                guard let r = session.bounds(p.range).rect else { continue }
                if let v = visible, !v.intersects(r) { continue }
                let revertable = recents.contains { $0.pillId == p.id }
                items.append(.pill(id: p.id, rect: r, revertable: revertable))
                if revertable { ph.append((r, p.until, p.id)) }
            }
        }
        let why: String
        if let f = field {
            if !owned(f, by: front) { why = "focused field isn't in the frontmost app (field pid \(f.pid) \(bundle(f.pid)), frontmost pid \(front) \(bundle(front)))" }
            else if mode != .ax { why = "not on the accessibility path" }
            else if tracker.isEmpty && pills.isEmpty { why = "no marks" }
            else { why = "\(items.count) of \(tracker.marks.count + pills.count) drawn (\(cached) from the last good position), \(hidden) outside the visible field" }
        } else { why = "no field" }
        if let n = boundsNote, n.hasPrefix("no source") { log.notice("bounds failed: \(n, privacy: .public)") }
        lock.lock()
        markHits = mh; pillHits = ph; dMarks = tracker.marks.count; dDrawn = why
        if let n = boundsNote { dBounds = n }
        if let src = field?.boundsSource { dSource = src }
        if let f = field { dPids = "field pid \(f.pid) (\(bundle(f.pid))), frontmost pid \(front) (\(bundle(front)))" }
        lock.unlock()
        if items.isEmpty && overlayEmpty { stopTimer(); return }
        overlayEmpty = items.isEmpty
        DispatchQueue.main.async { self.overlay.show(items) }
        if items.isEmpty { stopTimer() } else { startTimer() }
    }

    /// while anything is drawn: follow the text (scrolling has no AX notification)
    private func startTimer() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 0.4, repeating: 0.4)
        t.setEventHandler { [weak self] in self?.refresh() }
        t.resume()
        timer = t
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }
}

/// AXObserver callback (main run loop)
private func axCallback(_ obs: AXObserver, _ el: AXUIElement, _ note: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let r = refcon else { return }
    Unmanaged<TextLayer>.fromOpaque(r).takeUnretainedValue().axNotified(note as String)
}
