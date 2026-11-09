import AppKit
import Foundation

/// Reads mac-latest.json from the Nest mirror; a newer version opens its download link.
enum Updater {
    static let latestUrl = "https://autocorrect.mostlime.hackclub.app/autocorrect-android/mac-latest.json"

    struct Latest: Decodable {
        let version: String
        let url: String
        let sha256: String?
        let size: Int?
        let notes: String?
    }

    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }

    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    static func fetch() async -> Latest? {
        guard let u = URL(string: "\(latestUrl)?t=\(Int(Date().timeIntervalSince1970))") else { return nil }
        var req = URLRequest(url: u)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Latest.self, from: data)
    }

    /// userInitiated: also say "up to date" / "couldn't check"
    @MainActor static func check(userInitiated: Bool) async {
        let l = await fetch()
        guard let l = l else {
            if userInitiated { alert("Couldn't check for updates", "The update server didn't answer. Try again later.") }
            return
        }
        if newer(l.version, than: currentVersion) {
            let a = NSAlert()
            a.messageText = "Autocorrect \(l.version) is available"
            a.informativeText = "You have \(currentVersion).\n\n\(l.notes ?? "")\n\nDownload the zip, unzip it and replace the app in Applications. " +
                "macOS will ask for Accessibility permission again (the app is ad-hoc signed)."
            a.addButton(withTitle: "Download")
            a.addButton(withTitle: "Later")
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() == .alertFirstButtonReturn, let u = URL(string: l.url) { NSWorkspace.shared.open(u) }
        } else if userInitiated {
            alert("You're up to date", "Autocorrect \(currentVersion) is the latest version.")
        }
    }

    @MainActor static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
