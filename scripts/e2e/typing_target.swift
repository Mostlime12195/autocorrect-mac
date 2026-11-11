// E2E typing check (CI, workflow e2e.yml): a window with a plain NSTextView, keys posted as real HID events with a
// script of typos while Keylime runs, then the text is compared word by word with what it should become.
// Usage: typing_target [ms per key] [--post-only]   (--post-only: no window, type into whatever is in front, e.g. the
// Electron target in scripts/e2e/electron, which checks the text itself)
import AppKit

let typed = "can you hlep me with teh thing becuase i dont know and im sure it is wierd so i think youre right and thats it "
let want  = "can you help me with the thing because I don't know and I'm sure it is weird so I think you're right and that's it "
let msPerKey = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 60 : 60

print("e2e: AXIsProcessTrusted (this process) = \(AXIsProcessTrusted())")

func post(_ s: String) {
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: s == " " ? 49 : 0, keyDown: down) else { continue }
        var u = Array(s.utf16)
        e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
        e.post(tap: .cghidEventTap)
    }
}

if CommandLine.arguments.contains("--post-only") {
    sleep(2)
    for c in typed { post(String(c)); usleep(useconds_t(msPerKey * 1000)) }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let win = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 300))
tv.isAutomaticSpellingCorrectionEnabled = false
tv.isAutomaticTextReplacementEnabled = false
tv.isAutomaticQuoteSubstitutionEnabled = false
tv.isAutomaticDashSubstitutionEnabled = false
tv.isContinuousSpellCheckingEnabled = false
tv.font = NSFont.systemFont(ofSize: 16)
win.contentView = tv
win.title = "Keylime e2e"
win.makeKeyAndOrderFront(nil)
win.makeFirstResponder(tv)
app.activate(ignoringOtherApps: true)

DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
    DispatchQueue.main.sync { app.activate(ignoringOtherApps: true); win.makeKeyAndOrderFront(nil); win.makeFirstResponder(tv) }
    for c in typed {
        post(String(c))
        usleep(useconds_t(msPerKey * 1000))
    }
    sleep(4)
    DispatchQueue.main.sync {
        let got = tv.string
        print("e2e: typed: \(typed.debugDescription)")
        print("e2e: got:   \(got.debugDescription)")
        print("e2e: want:  \(want.debugDescription)")
        let t = typed.split(separator: " "), g = got.split(separator: " "), w = want.split(separator: " ")
        var fixes = 0, targets = 0, wrong = 0
        for i in 0..<min(t.count, w.count) where t[i] != w[i] {
            targets += 1
            if i < g.count && g[i] == w[i] { fixes += 1 } else { print("e2e: missed '\(t[i])' -> '\(i < g.count ? String(g[i]) : "?")' (want '\(w[i])')") }
        }
        for i in 0..<min(t.count, w.count, g.count) where t[i] == w[i] && g[i] != w[i] { wrong += 1; print("e2e: changed '\(t[i])' -> '\(g[i])'") }
        print("E2E RESULT (\(Int(msPerKey)) ms/key): \(fixes) of \(targets) typos fixed, \(wrong) correct words changed, words \(g.count)/\(w.count)")
        exit(0)
    }
}
app.run()
