import AppKit
import Foundation
import KeylimeCore
import Security

/// Self-update from mac-latest.json on the Nest mirror: download the zip, check its size and sha256, unzip it, check
/// it's signed by the same certificate as this copy (same designated requirement, so the Accessibility grant stays),
/// then a small detached script swaps the bundle in place once we've quit and relaunches it.
@MainActor
final class Updater {
    static let shared = Updater()
    nonisolated static let latestUrl = "https://autocorrect.mostlime.hackclub.app/autocorrect-android/mac-latest.json"
    nonisolated static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }

    private(set) var available: LatestInfo?
    private(set) var installing = false
    var onChange: (() -> Void)?
    private var timer: Timer?
    private let settings = Settings.shared

    /// a check shortly after launch, then once a day
    func startAutomaticChecks() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in Task { @MainActor in await Updater.shared.dailyCheck() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { Task { @MainActor in await Updater.shared.dailyCheck() } }
    }

    private func dailyCheck() async {
        guard settings.checkUpdates, !installing else { return }
        if let last = settings.lastUpdateCheck, Date().timeIntervalSince(last) < 23 * 3600 { return }
        await check(userInitiated: false)
    }

    static func fetch() async -> LatestInfo? {
        guard let u = URL(string: "\(latestUrl)?cb=\(UInt32.random(in: 0...UInt32.max))") else { return nil }
        var req = URLRequest(url: u)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? UpdateCore.parse(data)
    }

    /// userInitiated: also say "up to date" / "couldn't check"
    func check(userInitiated: Bool) async {
        settings.lastUpdateCheck = Date()
        guard let l = await Self.fetch() else {
            if userInitiated { Self.alert("Couldn't check for updates", "The update server didn't answer. Try again later.") }
            return
        }
        guard UpdateCore.newer(l.version, than: Self.currentVersion) else {
            available = nil
            onChange?()
            if userInitiated { Self.alert("You're up to date", "Keylime \(Self.currentVersion) is the latest version.") }
            return
        }
        available = l
        onChange?()
        prompt(l)
    }

    func prompt(_ l: LatestInfo) {
        let a = NSAlert()
        a.messageText = "Keylime \(l.version) is available"
        a.informativeText = "You have \(Self.currentVersion).\n\n\(l.notes ?? "")"
        a.addButton(withTitle: "Install & Relaunch")
        a.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { Task { await install(l) } }
    }

    struct Failure: Error, CustomStringConvertible { let description: String }

    func install(_ l: LatestInfo) async {
        guard !installing else { return }
        installing = true
        onChange?()
        defer { installing = false; onChange?() }
        do {
            let app = Bundle.main.bundleURL
            let dir = app.deletingLastPathComponent()
            if app.path.contains("/AppTranslocation/") {
                throw Failure(description: "Keylime is running from a temporary copy macOS made. Move Keylime.app to Applications, open it from there, and update again.")
            }
            guard FileManager.default.isWritableFile(atPath: dir.path) else {
                throw Failure(description: "Keylime can't replace itself in \(dir.path).")
            }
            guard let src = URL(string: l.url + "?cb=\(UInt32.random(in: 0...UInt32.max))") else { throw Failure(description: "bad download URL") }
            let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
            let (tmp, resp) = try await URLSession.shared.download(from: src)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(description: "download failed (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0))") }
            let zip = work.appendingPathComponent("update.zip")
            try FileManager.default.moveItem(at: tmp, to: zip)
            try UpdateCore.verify(zip, l)
            let unz = work.appendingPathComponent("new", isDirectory: true)
            guard await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unz.path]) == 0 else { throw Failure(description: "couldn't unzip the update") }
            try? FileManager.default.removeItem(at: zip)
            guard let newApp = try FileManager.default.contentsOfDirectory(at: unz, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }),
                  let info = Bundle(url: newApp)?.infoDictionary else { throw Failure(description: "the update has no app in it") }
            guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else { throw Failure(description: "the update is a different app") }
            guard info["CFBundleShortVersionString"] as? String == l.version else { throw Failure(description: "the update's version doesn't match") }
            if let why = CodeIdentity.mismatch(newApp) { throw Failure(description: why) }
            _ = await Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
            let script = work.appendingPathComponent("swap.sh")
            try Self.swapScript.write(to: script, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), app.path, newApp.path, work.path]
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            NSApp.terminate(nil)
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn't install the update"
            a.informativeText = "\(error)\n\nYou can download Keylime \(l.version) and replace the app yourself."
            a.addButton(withTitle: "Download")
            a.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() == .alertFirstButtonReturn, let u = URL(string: l.url) { NSWorkspace.shared.open(u) }
        }
    }

    /// waits for the old copy to quit, swaps the bundles (rolls back if that fails), relaunches, cleans up
    static let swapScript = """
    #!/bin/bash
    pid="$1"; old="$2"; new="$3"; work="$4"
    for i in $(seq 1 150); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    bak="$work/previous.app"
    if mv "$old" "$bak"; then
      if mv "$new" "$old"; then rm -rf "$bak"; else mv "$bak" "$old"; fi
    fi
    /usr/bin/xattr -dr com.apple.quarantine "$old" 2>/dev/null
    /usr/bin/open "$old"
    rm -rf "$work"
    """

    nonisolated static func run(_ path: String, _ args: [String]) async -> Int32 {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                do { try p.run(); p.waitUntilExit(); cont.resume(returning: p.terminationStatus) } catch { cont.resume(returning: -1) }
            }
        }
    }

    static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

/// This copy's code signature vs another bundle's.
enum CodeIdentity {
    /// this copy's designated requirement as text (nil if unsigned)
    static func ownRequirement() -> String? {
        guard let req = ownRequirementRef() else { return nil }
        var s: CFString?
        guard SecRequirementCopyString(req, [], &s) == errSecSuccess, let str = s else { return nil }
        return str as String
    }

    private static func ownRequirementRef() -> SecRequirement? {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let code = me else { return nil }
        var st: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &st) == errSecSuccess, let sc = st else { return nil }
        var req: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(sc, [], &req) == errSecSuccess else { return nil }
        return req
    }

    /// nil when `app` is validly signed and satisfies this copy's designated requirement (same certificate + bundle id)
    static func mismatch(_ app: URL) -> String? {
        guard let req = ownRequirementRef(), let text = ownRequirement() else { return "this copy of Keylime isn't signed" }
        if text.contains("cdhash") { return "this copy of Keylime is ad-hoc signed, so it can't check an update's signature" }
        var st: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &st) == errSecSuccess, let sc = st else { return "the update isn't signed" }
        // kSecCSCheckNestedCode | kSecCSStrictValidate
        let flags = SecCSFlags(rawValue: (1 << 3) | (1 << 4))
        let r = SecStaticCodeCheckValidity(sc, flags, req)
        return r == errSecSuccess ? nil : "the update isn't signed by the Keylime certificate (error \(r))"
    }
}
