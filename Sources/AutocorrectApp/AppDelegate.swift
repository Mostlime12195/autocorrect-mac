import AppKit
import ApplicationServices
import Engine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var engine: EngineHost!
    private var input: InputController!
    private let store = ModelStore()
    private let settings = Settings.shared
    private var user: UserData!
    private var permissionWindow: NSWindow?
    private let permissionModel = PermissionModel()
    private var permissionTimer: Timer?
    private var listsWindow: NSWindow?
    private var listsModel: ListsModel?
    private var downloadStatus: String?
    private var installing = false

    func applicationDidFinishLaunching(_ note: Notification) {
        let sup = Settings.supportDir
        user = UserData(dict: sup.appendingPathComponent("dictionary.txt"), learn: sup.appendingPathComponent("learned.tsv"))
        engine = EngineHost(user: user)
        engine.onChange = { [weak self] in self?.refreshIcon() }
        if let lex = Bundle.main.url(forResource: "lexicon", withExtension: "tsv") {
            engine.start(lexicon: lex)
        } else {
            engine.setStatus("lexicon.tsv missing from the app bundle", ready: false)
        }
        input = InputController(engine: engine)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        statusItem.menu = menu
        refreshIcon()

        if AXIsProcessTrusted() && input.start() {
            // ok
        } else {
            showPermission()
        }
        Task { await prepareModel() }
        if settings.checkUpdates {
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { Task { await Updater.check(userInitiated: false) } }
        }
    }

    // MARK: model

    @MainActor
    private func prepareModel() async {
        guard !installing else { return }
        installing = true
        defer { installing = false }
        if store.manifest == nil { downloadStatus = "Fetching model list…"; refreshIcon() }
        let m = await store.refreshManifest()
        guard let manifest = m, let spec = manifest.spec(settings.modelId) else {
            downloadStatus = "Couldn't reach the model server (retry from the menu)"
            refreshIcon()
            return
        }
        if !store.isInstalled(spec) {
            do {
                try await store.install(spec) { [weak self] p in
                    DispatchQueue.main.async {
                        self?.downloadStatus = String(format: "Downloading %@… %d%%", spec.label, Int(p * 100))
                        self?.refreshIcon()
                    }
                }
            } catch {
                downloadStatus = "Download failed: \(error)"
                refreshIcon()
                return
            }
        }
        downloadStatus = nil
        engine.load(spec: spec, graph: store.url(spec.graph), vocab: store.url(spec.vocab))
    }

    private func selectModel(_ id: String) {
        settings.modelId = id
        Task { await prepareModel() }
    }

    // MARK: permission

    private func showPermission() {
        if permissionWindow == nil {
            let v = PermissionView(model: permissionModel, openSettings: { [weak self] in self?.openAccessibilitySettings() },
                                   relaunch: { [weak self] in self?.relaunch() })
            permissionWindow = makeWindow("Autocorrect", v)
        }
        NSApp.activate(ignoringOtherApps: true)
        permissionWindow?.makeKeyAndOrderFront(nil)
        // registers the app in the Accessibility list (and shows the system prompt once)
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.checkPermission() }
    }

    private func checkPermission() {
        let ok = AXIsProcessTrusted()
        permissionModel.trusted = ok
        guard ok else { return }
        if input.start() {
            permissionTimer?.invalidate(); permissionTimer = nil
            permissionWindow?.close()
            refreshIcon()
        }
    }

    private func openAccessibilitySettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(u) }
    }

    private func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    // MARK: menu

    private func refreshIcon() {
        guard let b = statusItem?.button else { return }
        let on = settings.enabled && input?.tapRunning == true && engine?.ready == true
        let name = on ? "text.badge.checkmark" : "text.badge.xmark"
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: "Autocorrect") {
            img.isTemplate = true
            b.image = img
            b.title = ""
        } else {
            b.title = on ? "ac" : "ac·"
        }
        b.appearsDisabled = !on
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status: String
        if input.tapRunning == false {
            status = "Needs Accessibility permission"
        } else if let d = downloadStatus {
            status = d
        } else {
            status = engine.status
        }
        menu.addItem(disabled(status))
        if engine.ready && engine.lastMs > 0 { menu.addItem(disabled(String(format: "Last word: %.0f ms · keyboard: %@", engine.lastMs, input.layoutName))) }
        menu.addItem(.separator())

        let on = NSMenuItem(title: "Autocorrect", action: #selector(toggleEnabled), keyEquivalent: "")
        on.state = settings.enabled ? .on : .off
        on.target = self
        menu.addItem(on)

        if let bid = input.frontmostBundleId, bid != Bundle.main.bundleIdentifier {
            let name = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first?.localizedName ?? bid
            let it = NSMenuItem(title: "Pause in \(name)", action: #selector(togglePauseApp(_:)), keyEquivalent: "")
            it.state = settings.isExcluded(bid) ? .on : .off
            it.representedObject = bid
            it.target = self
            menu.addItem(it)
        }

        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        if let m = store.manifest {
            let cur = m.spec(settings.modelId)?.id
            for s in m.models {
                let it = NSMenuItem(title: s.label + (store.isInstalled(s) ? "" : String(format: " (%.0f MB download)", Double(s.graph.size) / 1e6)),
                                    action: #selector(pickModel(_:)), keyEquivalent: "")
                it.state = s.id == cur ? .on : .off
                it.representedObject = s.id
                it.target = self
                sub.addItem(it)
            }
        } else {
            sub.addItem(disabled("Model list not loaded"))
        }
        sub.addItem(.separator())
        let retry = NSMenuItem(title: "Retry download / reload", action: #selector(retryModel), keyEquivalent: "")
        retry.target = self
        sub.addItem(retry)
        modelItem.submenu = sub
        menu.addItem(modelItem)

        menu.addItem(item("Personal Dictionary & Excluded Apps…", #selector(openLists)))
        if !input.tapRunning { menu.addItem(item("Grant Accessibility Permission…", #selector(openPermission))) }
        menu.addItem(.separator())
        menu.addItem(item("Check for Updates…", #selector(checkUpdates)))
        menu.addItem(item("Copy Debug Log", #selector(copyDebugLog)))
        menu.addItem(disabled("Version \(Updater.currentVersion)"))
        menu.addItem(item("Quit Autocorrect", #selector(quit), "q"))
    }

    private func item(_ title: String, _ sel: Selector, _ key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        it.target = self
        return it
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    @objc private func copyDebugLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(input.debugLog, forType: .string)
    }

    @objc private func toggleEnabled() { settings.enabled.toggle(); refreshIcon() }

    @objc private func togglePauseApp(_ sender: NSMenuItem) {
        guard let bid = sender.representedObject as? String else { return }
        settings.toggleExcluded(bid)
        listsModel?.reload()
    }

    @objc private func pickModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        selectModel(id)
    }

    @objc private func retryModel() { Task { await prepareModel() } }

    @objc private func openLists() {
        if listsWindow == nil {
            let m = ListsModel(user: user)
            listsModel = m
            listsWindow = makeWindow("Autocorrect", ListsView(model: m))
        }
        listsModel?.reload()
        NSApp.activate(ignoringOtherApps: true)
        listsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openPermission() { showPermission() }

    @objc private func checkUpdates() { Task { await Updater.check(userInitiated: true) } }

    @objc private func quit() { NSApp.terminate(nil) }
}
