import AppKit
import QuartzCore
import os

struct PopoverActions {
    let pick: (String) -> Void
    let ignore: () -> Void
    let add: () -> Void
}

/// What Keylime draws over other apps (main thread only): dotted underlines under flagged words, a pill that fades on a
/// replaced word (and a faint line while it can be clicked to revert), the preview bubble and the suggestion popover.
/// The overlay panels never take the mouse: clicks on marks are seen by the event tap and still reach the app; the
/// popover is the one window that takes clicks, and it never activates Keylime or takes the keyboard.
final class Overlay {
    enum Item {
        case mark(CGRect, spelling: Bool)
        case pill(id: Int, rect: CGRect, revertable: Bool)
    }

    private var panels: [(screen: CGRect, panel: NSPanel, view: OverlayView)] = []
    private var bubble: NSPanel?
    private var popover: NSPanel?
    var onPopoverFrame: ((CGRect?) -> Void)?
    private var lastItems: [Item] = []
    private var test: (rect: CGRect, until: Date)?
    private var shown = 0
    private let log = Logger(subsystem: "dev.mostlime.autocorrect-mac", category: "overlay")

    init() {
        rebuild()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) {
            [weak self] _ in self?.rebuild()
        }
    }

    /// AX / CG global coordinates (top-left origin, y down) <-> Cocoa (bottom-left origin); the formula is its own inverse
    static func flip(_ r: CGRect) -> CGRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    private static func panel(_ frame: CGRect, mouse: Bool) -> NSPanel {
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.ignoresMouseEvents = !mouse
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.animationBehavior = .none
        return p
    }

    private func rebuild() {
        for p in panels { p.panel.orderOut(nil) }
        panels = NSScreen.screens.map { s in
            let p = Self.panel(s.frame, mouse: false)
            let v = OverlayView(frame: CGRect(origin: .zero, size: s.frame.size))
            p.contentView = v
            return (s.frame, p, v)
        }
    }

    func show(_ items: [Item]) {
        lastItems = items
        render()
    }

    /// "Show Test Underline": a mark + pill at an AX rect for 4 s, to see the overlay draws at all
    func showTest(_ r: CGRect) {
        test = (r, Date().addingTimeInterval(4))
        render()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.1) { [weak self] in self?.render() }
    }

    /// main: what the overlay shows and where its windows are
    func diagnostics() -> String {
        let screens = NSScreen.screens.map { NSStringFromRect($0.frame) }.joined(separator: ", ")
        let wins = panels.map { "\($0.panel.isVisible ? "visible" : "hidden") \(NSStringFromRect($0.panel.frame)) level \($0.panel.level.rawValue)" }
            .joined(separator: "; ")
        return "Overlay: \(lastItems.count) item(s) last pushed, \(shown) drawn on screens; windows: \(wins)\nScreens: \(screens)" +
            "\nPreview bubble: \(bubble == nil ? "hidden" : "visible \(NSStringFromRect(bubble!.frame))")"
    }

    private func render() {
        var items = lastItems
        if let t = test {
            if t.until > Date() {
                items.append(.mark(t.rect, spelling: true))
                items.append(.pill(id: -1, rect: t.rect.offsetBy(dx: 0, dy: -t.rect.height - 6), revertable: true))
            } else { test = nil }
        }
        if panels.count != NSScreen.screens.count { rebuild() }
        shown = 0
        for (frame, panel, view) in panels {
            var marks: [(CGRect, Bool)] = []
            var pills: [(Int, CGRect, Bool)] = []
            for it in items {
                switch it {
                case .mark(let r, let sp):
                    let c = Self.flip(r)
                    if c.intersects(frame) { marks.append((c.offsetBy(dx: -frame.minX, dy: -frame.minY), sp)) }
                case .pill(let id, let r, let rv):
                    let c = Self.flip(r)
                    if c.intersects(frame) { pills.append((id, c.offsetBy(dx: -frame.minX, dy: -frame.minY), rv)) }
                }
            }
            view.update(marks: marks, pills: pills)
            shown += marks.count + pills.count
            if marks.isEmpty && pills.isEmpty {
                if panel.isVisible { panel.orderOut(nil) }
            } else if !panel.isVisible {
                panel.orderFrontRegardless()
                if !panel.isVisible { log.error("overlay window didn't come up on screen \(NSStringFromRect(frame), privacy: .public)") }
            }
        }
        if !items.isEmpty && shown == 0 {
            log.notice("\(items.count) overlay item(s) fall outside every screen: \(items.map { "\($0)" }.joined(separator: " "), privacy: .public)")
        }
    }

    // MARK: preview bubble

    func showPreview(_ word: CGRect, _ text: String) {
        hidePreview()
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .labelColor
        let size = label.intrinsicContentSize
        let w = size.width + 16, h = size.height + 6
        let c = Self.flip(word)
        let p = Self.panel(CGRect(x: c.minX - 4, y: c.minY - h - 3, width: w, height: h), mouse: false)
        let bg = NSVisualEffectView(frame: CGRect(x: 0, y: 0, width: w, height: h))
        bg.material = .popover
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 6
        bg.layer?.masksToBounds = true
        bg.layer?.borderWidth = 0.5
        bg.layer?.borderColor = NSColor.separatorColor.cgColor
        label.frame = CGRect(x: 8, y: 3, width: size.width, height: size.height)
        bg.addSubview(label)
        p.contentView = bg
        p.hasShadow = true
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.12; p.animator().alphaValue = 1 }
        bubble = p
        log.info("preview bubble at \(NSStringFromRect(p.frame), privacy: .public)")
    }

    func hidePreview() {
        bubble?.orderOut(nil)
        bubble = nil
    }

    // MARK: suggestion popover

    func showPopover(below word: CGRect, word text: String, fixes: [String], actions: PopoverActions) {
        closePopover()
        var rows: [PopoverRow] = []
        for f in fixes.prefix(3) {
            rows.append(PopoverRow(title: f, bold: true) { [weak self] in self?.closePopover(); actions.pick(f) })
        }
        let sep = rows.count
        rows.append(PopoverRow(title: "Ignore", bold: false) { [weak self] in self?.closePopover(); actions.ignore() })
        rows.append(PopoverRow(title: "Add “\(text)” to Dictionary", bold: false) { [weak self] in self?.closePopover(); actions.add() })
        let rowH: CGFloat = 24, pad: CGFloat = 5
        let w = max(170, rows.map { $0.idealWidth }.max() ?? 0)
        let h = CGFloat(rows.count) * rowH + 2 * pad + (sep > 0 ? 9 : 0)
        let c = Self.flip(word)
        var origin = CGPoint(x: c.minX - 6, y: c.minY - h - 4)
        if let s = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: c.midX, y: c.midY)) })?.visibleFrame {
            if origin.y < s.minY { origin.y = c.maxY + 4 }   // no room below the word
            origin.x = min(max(origin.x, s.minX + 4), s.maxX - w - 4)
        }
        let p = Self.panel(CGRect(origin: origin, size: CGSize(width: w, height: h)), mouse: true)
        p.level = .popUpMenu
        p.hasShadow = true
        let bg = NSVisualEffectView(frame: CGRect(x: 0, y: 0, width: w, height: h))
        bg.material = .menu
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 8
        bg.layer?.masksToBounds = true
        bg.layer?.borderWidth = 0.5
        bg.layer?.borderColor = NSColor.separatorColor.cgColor
        var y = h - pad
        for (i, r) in rows.enumerated() {
            if i == sep && sep > 0 {
                y -= 9
                let line = NSBox(frame: CGRect(x: 10, y: y + 4, width: w - 20, height: 1))
                line.boxType = .separator
                bg.addSubview(line)
            }
            y -= rowH
            r.frame = CGRect(x: pad, y: y, width: w - 2 * pad, height: rowH)
            bg.addSubview(r)
        }
        p.contentView = bg
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.1; p.animator().alphaValue = 1 }
        popover = p
        onPopoverFrame?(Self.flip(p.frame))
    }

    func closePopover() {
        guard let p = popover else { return }
        p.orderOut(nil)
        popover = nil
        onPopoverFrame?(nil)
    }
}

/// One clickable line of the popover. Takes the first click (the popover is never key).
final class PopoverRow: NSView {
    private let label: NSTextField
    private let action: () -> Void
    private var hover = false { didSet { needsDisplay = true; label.textColor = hover ? .selectedMenuItemTextColor : .labelColor } }

    init(title: String, bold: Bool, action: @escaping () -> Void) {
        label = NSTextField(labelWithString: title)
        label.font = bold ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: 13)
        self.action = action
        super.init(frame: .zero)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    var idealWidth: CGFloat { label.intrinsicContentSize.width + 34 }

    override func layout() {
        super.layout()
        let s = label.intrinsicContentSize
        label.frame = CGRect(x: 12, y: (bounds.height - s.height) / 2, width: bounds.width - 20, height: s.height)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hover else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}

/// Underlines (drawn) and pills (layers, so they can fade on their own).
final class OverlayView: NSView {
    private var marks: [(CGRect, Bool)] = []
    private var pillLayers: [Int: (fill: CALayer, line: CALayer)] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    func update(marks: [(CGRect, Bool)], pills: [(Int, CGRect, Bool)]) {
        self.marks = marks
        needsDisplay = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let ids = Set(pills.map { $0.0 })
        for (id, l) in pillLayers where !ids.contains(id) {
            l.fill.removeFromSuperlayer(); l.line.removeFromSuperlayer(); pillLayers.removeValue(forKey: id)
        }
        for (id, r, revertable) in pills {
            let pr = r.insetBy(dx: -3, dy: -1)
            if let l = pillLayers[id] {
                l.fill.frame = pr
                l.line.frame = CGRect(x: r.minX, y: r.minY - 1, width: r.width, height: 1.5)
                l.line.opacity = revertable ? 0.7 : 0
                continue
            }
            let fill = CALayer()
            fill.frame = pr
            fill.cornerRadius = min(pr.height / 2, 7)
            fill.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.32).cgColor
            fill.opacity = 0
            let line = CALayer()
            line.frame = CGRect(x: r.minX, y: r.minY - 1, width: r.width, height: 1.5)
            line.backgroundColor = NSColor.controlAccentColor.cgColor
            line.cornerRadius = 0.75
            line.opacity = revertable ? 0.7 : 0
            layer?.addSublayer(fill)
            layer?.addSublayer(line)
            pillLayers[id] = (fill, line)
            // the replace animation: a highlight that fades over ~0.6 s
            let a = CAKeyframeAnimation(keyPath: "opacity")
            a.values = [0.0, 1.0, 1.0, 0.0]
            a.keyTimes = [0, 0.12, 0.35, 1]
            a.duration = 0.65
            fill.add(a, forKey: "pill")
        }
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        // macOS-style dotted underline: red for spelling, green for the rest (like the system's grammar marks)
        for (r, spelling) in marks {
            (spelling ? NSColor.systemRed : NSColor.systemGreen).setFill()
            let d: CGFloat = 2.6, step: CGFloat = 4.2
            let y = r.minY - d / 2 + 0.5
            var x = r.minX + 0.5
            while x + d <= r.maxX + 0.5 {
                NSBezierPath(ovalIn: CGRect(x: x, y: y, width: d, height: d)).fill()
                x += step
            }
        }
    }
}
