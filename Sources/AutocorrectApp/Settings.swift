import Foundation
import KeylimeCore

/// UserDefaults-backed settings (thread-safe reads via a cached snapshot).
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard
    private let lock = NSLock()

    /// terminals, IDEs, editors and password managers: off by default (prefix match for families)
    static let defaultExcluded = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "org.alacritty",
        "io.alacritty", "com.github.wez.wezterm", "com.mitchellh.ghostty", "co.zeit.hyper", "com.raphaelamorim.rio",
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium", "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf", "dev.zed.Zed", "dev.zed.Zed-Preview", "com.sublimetext.", "com.panic.Nova",
        "com.apple.dt.Xcode", "com.barebones.bbedit", "org.vim.MacVim", "com.neovide.neovide", "com.jetbrains.",
        "com.google.android.studio", "com.1password.", "com.agilebits.onepassword", "com.bitwarden.desktop",
        "com.apple.keychainaccess", "com.apple.Passwords",
    ]

    private var excludedCache: [String]

    init() {
        d.register(defaults: ["enabled": true, "holdMs": 200, "checkUpdates": true, "preview": false, "shareData": false, "shareContext": false])
        if d.array(forKey: "excludedApps") == nil { d.set(Self.defaultExcluded, forKey: "excludedApps") }
        excludedCache = d.stringArray(forKey: "excludedApps") ?? Self.defaultExcluded
        // 0.1.x had an on/off switch only
        if d.string(forKey: "mode") == nil && d.object(forKey: "enabled") != nil && !d.bool(forKey: "enabled") {
            d.set(CorrectionMode.off.rawValue, forKey: "mode")
        }
        modeCache = CorrectionMode.stored(d.string(forKey: "mode"))
    }

    private var modeCache: CorrectionMode

    /// suggest only (default) / auto (confident fixes applied, the rest underlined) / off
    var mode: CorrectionMode {
        get { lock.lock(); defer { lock.unlock() }; return modeCache }
        set { lock.lock(); modeCache = newValue; lock.unlock(); d.set(newValue.rawValue, forKey: "mode") }
    }

    var enabled: Bool { mode != .off }

    /// a bubble with the correction the current word is about to get (Space accepts, Esc cancels)
    var preview: Bool {
        get { d.bool(forKey: "preview") }
        set { d.set(newValue, forKey: "preview") }
    }

    /// the "turn off macOS autocorrect" question was shown once
    var askedSystemAutocorrect: Bool {
        get { d.bool(forKey: "askedSystemAutocorrect") }
        set { d.set(newValue, forKey: "askedSystemAutocorrect") }
    }

    /// model id; nil = the manifest default
    var modelId: String? {
        get { d.string(forKey: "model") }
        set { d.set(newValue, forKey: "model") }
    }

    /// how long a separator may wait for its correction before it goes out uncorrected
    var holdMs: Int { max(30, min(1000, d.integer(forKey: "holdMs"))) }

    // MARK: performance

    struct Perf: Equatable {
        /// pause before the sentences around the caret are re-checked
        var idleSecs: Double
        /// also re-check every N words while typing (0 = only after a pause)
        var everyWords: Int
        /// re-check the whole text box (else: sentences near the caret, a few per pass)
        var wholeField: Bool
        /// tokens of left context the model reads (64 = the original; m2 was trained on 1024)
        var ctxTokens: Int
        /// words near a sentence's end also see the next sentence
        var nextSentence: Bool

        /// characters of text handed over for that many tokens (~5 per token, with room)
        var leftChars: Int { Swift.max(320, ctxTokens * 5) }

        static let battery = Perf(idleSecs: 2.0, everyWords: 0, wholeField: false, ctxTokens: 64, nextSentence: false)
        // 256: measured on an M2 Pro (VM) at ~100 ms/word, same as 64; 1024 was ~265 ms/word, too slow to keep up
        static let balanced = Perf(idleSecs: 1.0, everyWords: 0, wholeField: false, ctxTokens: 256, nextSentence: false)
        static let max = Perf(idleSecs: 0.3, everyWords: 2, wholeField: true, ctxTokens: 1024, nextSentence: true)
        static let presets: [(String, String, Perf)] = [("battery", "Battery saver", battery), ("balanced", "Balanced", balanced), ("max", "Max", max)]

        var presetId: String { Self.presets.first { $0.2 == self }?.0 ?? "custom" }
    }

    var perf: Perf {
        get {
            Perf(idleSecs: min(3, max(0.2, d.object(forKey: "perfIdleSecs") as? Double ?? 1.0)),
                 everyWords: min(10, max(0, d.object(forKey: "perfEveryWords") as? Int ?? 0)),
                 wholeField: d.bool(forKey: "perfWholeField"),
                 ctxTokens: min(1024, max(64, d.object(forKey: "perfCtxTokens") as? Int ?? Perf.balanced.ctxTokens)),
                 nextSentence: d.bool(forKey: "perfNextSentence"))
        }
        set {
            d.set(newValue.idleSecs, forKey: "perfIdleSecs")
            d.set(newValue.everyWords, forKey: "perfEveryWords")
            d.set(newValue.wholeField, forKey: "perfWholeField")
            d.set(newValue.ctxTokens, forKey: "perfCtxTokens")
            d.set(newValue.nextSentence, forKey: "perfNextSentence")
        }
    }

    // MARK: data sharing (opt-in, off by default; docs/upload-schema.md)

    /// upload word-level correction events
    var shareData: Bool {
        get { d.bool(forKey: "shareData") }
        set { d.set(newValue, forKey: "shareData") }
    }

    /// "Include sentence context": its own opt-in, off by default, and only ever on while sharing is on
    var shareContext: Bool {
        get { d.bool(forKey: "shareData") && d.bool(forKey: "shareContext") }
        set { d.set(newValue, forKey: "shareContext") }
    }

    /// random per-install id (not tied to the Mac or the user); a new one after "Delete my uploaded data"
    var installId: String {
        if let v = d.string(forKey: "installId") { return v }
        return rotateInstallId()
    }

    @discardableResult
    func rotateInstallId() -> String {
        let v = UUID().uuidString.lowercased()
        d.set(v, forKey: "installId")
        return v
    }

    /// install ids whose server-side delete hasn't gone through yet (retried before any upload)
    var pendingDeletes: [String] {
        get { d.stringArray(forKey: "pendingDeletes") ?? [] }
        set { d.set(Array(Set(newValue)).sorted(), forKey: "pendingDeletes") }
    }

    static let uploadURL = "https://autocorrect.mostlime.hackclub.app/api/v1/upload"

    var checkUpdates: Bool {
        get { d.bool(forKey: "checkUpdates") }
        set { d.set(newValue, forKey: "checkUpdates") }
    }

    var lastUpdateCheck: Date? {
        get { d.object(forKey: "lastUpdateCheck") as? Date }
        set { d.set(newValue, forKey: "lastUpdateCheck") }
    }

    var excluded: [String] {
        lock.lock(); defer { lock.unlock() }
        return excludedCache
    }

    func setExcluded(_ v: [String]) {
        lock.lock(); excludedCache = v; lock.unlock()
        d.set(v, forKey: "excludedApps")
    }

    func isExcluded(_ bundleId: String?) -> Bool {
        guard let b = bundleId else { return false }
        return excluded.contains { $0.hasSuffix(".") ? b.hasPrefix($0) : b == $0 }
    }

    /// pause / resume one app (exact bundle id)
    func toggleExcluded(_ bundleId: String) {
        var v = excluded
        if isExcluded(bundleId) {
            v.removeAll { $0 == bundleId || ($0.hasSuffix(".") && bundleId.hasPrefix($0)) }
        } else {
            v.append(bundleId)
        }
        setExcluded(v)
    }

    /// the 0.1.x folder name: kept so the personal dictionary carries over
    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let u = base.appendingPathComponent("Autocorrect", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}
