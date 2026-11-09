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
        d.register(defaults: ["enabled": true, "holdMs": 200, "checkUpdates": true, "preview": false])
        if d.array(forKey: "excludedApps") == nil { d.set(Self.defaultExcluded, forKey: "excludedApps") }
        excludedCache = d.stringArray(forKey: "excludedApps") ?? Self.defaultExcluded
        // 0.1.x had an on/off switch only
        if d.string(forKey: "mode") == nil && d.object(forKey: "enabled") != nil && !d.bool(forKey: "enabled") {
            d.set(CorrectionMode.off.rawValue, forKey: "mode")
        }
        modeCache = CorrectionMode(rawValue: d.string(forKey: "mode") ?? "") ?? .auto
    }

    private var modeCache: CorrectionMode

    /// auto (confident fixes applied, the rest underlined) / suggest only / off
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
