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
    static let CTX_CHARS = 400
    static let IDLE_CHARS = 2000
    static let IDLE_LEFT = 200
    static let IDLE_SENTENCES = 6

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
    func scrolled() { q.async { self.scheduleRefresh(after: 0.06) } }

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
        scheduleIdle(seq)
        scheduleRefresh(after: 0.05)
    }

    private func clicked(_ p: CGPoint) {
        lock.lock()
        let hit = markHits.last { $0.rect.insetBy(dx: -1, dy: -3).contains(p) }
        lock.unlock()
        closePopover()
        guard let h = hit else { return }
        // after the click has put the caret there
        q.asyncAfter(deadline: .now() + 0.12) { self.showPopover(h.id) }
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
        return a != "?" && b != "?" && a.hasPrefix(b)
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
        lock.lock(); dRole = role; lock.unlock()
        noWrite.removeAll { Date().timeIntervalSince($0.at) > 60 }
        if f.isSecure { setMode(.ax, "password field: nothing happens here"); return }
        if let n = noWrite.first(where: { CFEqual($0.el, f.el) }), n.fails >= 2 {
            setMode(.keys, "accessibility writes failed here twice (\(f.lastWrite)); retrying in a minute"); return
        }
        if let why = f.whyNotReadable() { setMode(.keys, "\(role): \(why)"); return }
        setMode(.ax, "\(role): text readable")
    }

    private func switchField(_ f: AXField?) {
        if f == nil { focus.reset() }
        if field == nil && f == nil { updateMode(nil); return }
        lock.lock(); dMarks = 0; lock.unlock()
        tracker.removeAll(); pills.removeAll(); recents.removeAll(); prev = nil; keepOnce = nil
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
        let (left, sp) = TypingCore.splitLeft(textBefore(snap, start, Self.CTX_CHARS))
        let input = WordInput(typed: word, left: left, sep: sp)
        var pw: PrevWord? = nil
        var merge: MergeInput? = nil
        var used: PrevInfo? = nil
        if let p = prev, !sp.contains("\n"), p.start + p.out.utf16.count + sp.utf16.count == start, left.hasSuffix(p.out),
           snap.sub(NSRange(location: p.start, length: p.out.utf16.count)) == p.out {
            let (lp, sepp) = TypingCore.splitLeft(textBefore(snap, p.start, Self.CTX_CHARS))
            pw = PrevWord(slot: p.slot, idx: p.idx, left: lp, sep: sepp, lmScored: p.lmScored, margin: p.margin, scores: p.scores)
            merge = MergeInput(prevTyped: p.typed)
            used = p
        }
        prev = nil
        engine.correctWord(input, prev: pw, merge: merge) { [weak self] r, inLex in
            self?.q.async { self?.resolved(f, word, sep, start, seq, r, inLex, used) }
        }
    }

    private func resolved(_ f: AXField, _ word: String, _ sep: String, _ start: Int, _ seq: Int, _ r: WordResult?, _ inLex: Bool,
                          _ used: PrevInfo?) {
        guard let r = r, f.same(field), usableField() != nil else { return }
        let o = WordOutcome(r, typedOOV: !inLex)
        let userWord = engine.user.has(word) || ignored.contains(word.lowercased())
        let d = Policy.boundary(o, mode: settings.mode, hasPrev: used != nil, prevOut: used?.out, userWord: userWord,
                                penalty: { [engine] a, b in engine.user.penalty(a, b) })
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
            let res = write(f, range, old: oldText, new: newText)
            noteWord(String(format: "fixed (margin %.1f): write ", o.margin) + "\(res)")
            switch res {
            case .ok:
                let newLen = (newText as NSString).length
                edited(at: spanStart, oldLen: range.length, newLen: newLen)
                let pid = addPill(NSRange(location: spanStart, length: newLen), newText)
                recents.append(Recent(start: spanStart, newText: newText, oldText: oldText, word: word, learnTyped: merged ? oldText : word,
                                      out: out, sep: sep, pillId: pid, until: Date().addingTimeInterval(Self.REVERT_SECS)))
                if recents.count > 6 { recents.removeFirst() }
                // backspace undoes it while nothing else was typed after the separator
                lock.lock(); if keySeq == seq { undoArmed = seq }; lock.unlock()
                if !merged { setPrev(out, spanStart + newLen - (out as NSString).length) }
                pushOverlay()
            case .unsupported:
                writesFailed(f)
            case .changed:
                break
            }
        }
    }

    /// one AX write with the user's keys held back meanwhile
    private func write(_ f: AXField, _ r: NSRange, old: String, new: String) -> AXField.Write {
        var res = AXField.Write.changed
        input.gate { res = f.replace(r, old: old, new: new) }
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
        let res = write(f, range, old: old, new: rc.oldText)
        input.debugNote("ax: revert \"\(old)\" -> \"\(rc.oldText)\" \(res)")
        guard res == .ok else { if viaBackspace { input.postBackspace() }; return }
        let newLen = (rc.oldText as NSString).length
        edited(at: rc.start, oldLen: range.length, newLen: newLen)
        pills.removeAll { $0.id == rc.pillId }
        keepOnce = (rc.start + newLen - (rc.word as NSString).length, rc.word)
        prev = nil
        // same as backspace-undo on Android: that edit needs more evidence for a week (and a non-word typed on purpose
        // goes in the personal dictionary)
        engine.user.suppress(rc.learnTyped, rc.out)
        input.learn(Undone(typed: rc.learnTyped, out: rc.out))
        pushOverlay()
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
        let (left, sp) = TypingCore.splitLeft(textBefore(snap, a, Self.CTX_CHARS))
        engine.correctWord(WordInput(typed: word, left: left, sep: sp), prev: nil, merge: nil) { [weak self] r, inLex in
            self?.q.async {
                guard let self = self, let r = r, self.seqNow == seq, f.same(self.field) else { return }
                let d = Policy.boundary(WordOutcome(r, typedOOV: !inLex), mode: .auto, hasPrev: false, prevOut: nil, userWord: false,
                                        penalty: { [engine = self.engine] x, y in engine.user.penalty(x, y) })
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
        q.asyncAfter(deadline: .now() + Self.IDLE_SECS, execute: w)
    }

    private func idle(_ seq: Int) {
        guard seqNow == seq else { return }
        guard let f = usableField() else { noteIdle("skipped: \(notUsableWhy())"); return }
        guard let snap = f.snapshot(), snap.selLength == 0 else { noteIdle("skipped: field text unreadable or a selection"); return }
        let caretRel = snap.caret - snap.base
        let lo = max(0, caretRel - Self.IDLE_CHARS), hi = min(snap.ns.length, caretRel + Self.IDLE_CHARS)
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
        var todo: [(range: Range<Int>, key: String, left: String)] = []
        for r in SentenceCheck.split(text) {
            let left = String(chars[max(0, r.lowerBound - Self.IDLE_LEFT)..<r.lowerBound])
            let key = left + "\u{1}" + String(chars[r])
            if sentenceCache[key] == nil { todo.append((r, key, left)) }
        }
        guard !todo.isEmpty else { noteIdle("nothing new to check"); return }
        // nearest to the caret first
        todo.sort { dist($0.range, caretChar) < dist($1.range, caretChar) }
        let batch = Array(todo.prefix(Self.IDLE_SENTENCES))
        let reqs = batch.map { SentenceReq(left: $0.left, sentence: String(chars[$0.range])) }
        let more = todo.count > batch.count
        engine.checkSentences(reqs, cancelled: { [weak self] in self?.seqNow != seq }) { [weak self] res in
            self?.q.async {
                guard let self = self else { return }
                guard let res = res, self.seqNow == seq, f.same(self.field), let s2 = f.snapshot(),
                      s2.base == snap.base, s2.caret == snap.caret, s2.text == snap.text else { self.noteIdle("dropped: typing resumed or the text changed"); return }
                self.noteIdle("checked \(res.count) sentence(s), \(res.reduce(0) { $0 + $1.count }) flagged")
                var applies: [(range: NSRange, from: String, to: String)] = []
                for (j, fixes) in res.enumerated() {
                    let b = batch[j]
                    self.cache(b.key, fixes)
                    let s0 = winBase + offs[b.range.lowerBound], s1 = winBase + offs[b.range.upperBound]
                    self.tracker.removeAll(in: s0..<s1)
                    let current = b.range.lowerBound <= caretChar && caretChar <= b.range.upperBound
                    for (fx, spelling) in fixes {
                        let a = winBase + offs[b.range.lowerBound + fx.start]
                        let len = (fx.from as NSString).length
                        let userWord = self.engine.user.has(fx.from) || self.ignored.contains(fx.from.lowercased())
                        switch Policy.idle(gap: fx.gap, spelling: spelling, mode: self.settings.mode,
                                           inCurrentSentence: current && a + len <= snap.caret, userWord: userWord) {
                        case .apply: applies.append((NSRange(location: a, length: len), fx.from, fx.to))
                        case .flag: self.tracker.add(start: a, word: fx.from, fixes: fx.fixes, spelling: spelling)
                        case .none: break
                        }
                    }
                }
                // writes last, right to left so earlier offsets hold, and only while the user still isn't typing
                for ap in applies.sorted(by: { $0.range.location > $1.range.location }) {
                    guard self.seqNow == seq else { break }
                    let r = self.write(f, ap.range, old: ap.from, new: ap.to)
                    self.noteIdle("fixed a word after the pause: write \(r)")
                    if r == .unsupported { self.writesFailed(f); break }
                    guard r == .ok else { continue }
                    let newLen = (ap.to as NSString).length
                    self.edited(at: ap.range.location, oldLen: ap.range.length, newLen: newLen)
                    let pid = self.addPill(NSRange(location: ap.range.location, length: newLen), ap.to)
                    self.recents.append(Recent(start: ap.range.location, newText: ap.to, oldText: ap.from, word: ap.from, learnTyped: ap.from,
                                               out: ap.to, sep: "", pillId: pid, until: Date().addingTimeInterval(Self.REVERT_SECS)))
                }
                self.pushOverlay()
                if more { self.scheduleIdle(seq) }
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

    private func showPopover(_ id: Int) {
        guard let f = field, let m = tracker.mark(id: id), let snap = f.snapshot(),
              snap.sub(NSRange(location: m.start, length: m.length)) == m.word,
              let rect = f.bounds(NSRange(location: m.start, length: m.length)) else { return }
        popoverMark = id
        let actions = PopoverActions(
            pick: { [weak self] s in self?.q.async { self?.applyFix(id, s) } },
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
        guard let f = field, let m = tracker.mark(id: id) else { return }
        let range = NSRange(location: m.start, length: m.length)
        let r = write(f, range, old: m.word, new: to)
        input.debugNote("ax: pick \"\(m.word)\" -> \"\(to)\" \(r)")
        if r == .unsupported { writesFailed(f) }
        guard r == .ok else { return }
        tracker.remove(id: id)
        let newLen = (to as NSString).length
        edited(at: m.start, oldLen: m.length, newLen: newLen)
        _ = addPill(NSRange(location: m.start, length: newLen), to, revertable: false)
        pushOverlay()
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
            "Test underline: \(dTest)",
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
                let (b, detail) = f.boundsDetail(range)
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
            tracker.removeAll(); pills.removeAll(); recents.removeAll()
        }
        pills.removeAll { $0.until < now }
        let lastId = recents.last?.pillId
        recents.removeAll { $0.until < now && $0.pillId != lastId }
        if let f = field, !(tracker.isEmpty && pills.isEmpty), let snap = f.snapshot() {
            tracker.reconcile(snap.text, base: snap.base)
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
        if let f = field, owned(f, by: front), mode == .ax, !(tracker.isEmpty && pills.isEmpty) {
            let visible = f.visibleFrame()
            let t0 = Date()
            for m in tracker.marks.suffix(40) {
                if Date().timeIntervalSince(t0) > 0.15 { break }   // a slow app: draw what we have
                let (b, detail) = f.boundsDetail(NSRange(location: m.start, length: m.length))
                boundsNote = detail
                guard let r = b else { continue }
                if let v = visible, !v.intersects(r) { hidden += 1; continue }
                items.append(.mark(r, spelling: m.spelling))
                mh.append((r, m.id))
            }
            for p in pills where p.until > now {
                guard let r = f.bounds(p.range) else { continue }
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
            else { why = "\(items.count) of \(tracker.marks.count + pills.count) drawn, \(hidden) outside the visible field" }
        } else { why = "no field" }
        if let n = boundsNote, !n.hasPrefix("ok") { log.notice("bounds failed: \(n, privacy: .public)") }
        lock.lock()
        markHits = mh; pillHits = ph; dMarks = tracker.marks.count; dDrawn = why
        if let n = boundsNote { dBounds = n }
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
