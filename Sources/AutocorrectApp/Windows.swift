import AppKit
import ApplicationServices
import Engine
import KeylimeCore
import SwiftUI

// MARK: onboarding (Accessibility permission)

final class PermissionModel: ObservableObject {
    @Published var trusted = AXIsProcessTrusted()
    @Published var systemAutocorrect = SystemAutocorrect.isOn
}

struct PermissionView: View {
    @ObservedObject var model: PermissionModel
    let openSettings: () -> Void
    let relaunch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Keylime needs Accessibility access").font(.title2).bold()
            Text("It reads the text field you're typing in, fixes typos it's sure about and underlines the rest, using a small language model that runs on this Mac. Nothing you type leaves your computer.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Click **Open System Settings**.")
                Text("2. Turn on **Keylime** under Privacy & Security → Accessibility (add it with + if it isn't listed). If an old **Autocorrect** entry is there, remove it.")
                Text("3. Come back here. This window closes by itself once access is granted.")
            }
            Toggle("Turn off macOS's own autocorrect so the two don't fight", isOn: Binding(
                get: { !model.systemAutocorrect },
                set: { off in SystemAutocorrect.set(!off); model.systemAutocorrect = SystemAutocorrect.isOn }))
            Text("Apps that are already open may need a restart to notice.")
                .font(.footnote).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Image(systemName: model.trusted ? "checkmark.circle.fill" : "hourglass")
                    .foregroundColor(model.trusted ? .green : .secondary)
                Text(model.trusted ? "Access granted" : "Waiting for access…").foregroundColor(.secondary)
                Spacer()
                Button("Relaunch", action: relaunch).help("If access is on but nothing happens, relaunch the app")
                Button("Open System Settings", action: openSettings).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 500)
    }
}

// MARK: settings

final class SettingsModel: ObservableObject {
    @Published var mode = Settings.shared.mode { didSet { Settings.shared.mode = mode; onChange?() } }
    @Published var preview = Settings.shared.preview { didSet { Settings.shared.preview = preview } }
    @Published var checkUpdates = Settings.shared.checkUpdates { didSet { Settings.shared.checkUpdates = checkUpdates } }
    @Published var systemAutocorrect = SystemAutocorrect.isOn
    @Published var perf = Settings.shared.perf { didSet { if perf != oldValue { Settings.shared.perf = perf; onPerf?(perf) } } }
    var onPerf: ((Settings.Perf) -> Void)?
    @Published var usage = ""
    var onChange: (() -> Void)?
    var openLists: (() -> Void)?
    var usageSource: (() -> String)?
    private var timer: Timer?
    func reload() {
        if mode != Settings.shared.mode { mode = Settings.shared.mode }
        systemAutocorrect = SystemAutocorrect.isOn
        perf = Settings.shared.perf
        usage = usageSource?() ?? ""
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.usage = self.usageSource?() ?? ""
        }
    }
    func stop() { timer?.invalidate(); timer = nil }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Corrections").font(.headline)
                Picker("", selection: $model.mode) {
                    Text("Fix confident typos, underline the rest").tag(CorrectionMode.auto)
                    Text("Suggest only (underline, never change text)").tag(CorrectionMode.suggest)
                    Text("Off").tag(CorrectionMode.off)
                }.pickerStyle(.radioGroup).labelsHidden()
                Toggle("Preview a correction while typing (Space accepts, Esc cancels)", isOn: $model.preview)
                    .disabled(model.mode != .auto)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("macOS autocorrect").font(.headline)
                Text("“Correct spelling automatically” is \(model.systemAutocorrect ? "on" : "off").")
                    .foregroundColor(.secondary)
                Toggle("Turn off macOS's own autocorrect (recommended)", isOn: Binding(
                    get: { !model.systemAutocorrect },
                    set: { off in SystemAutocorrect.set(!off); model.systemAutocorrect = SystemAutocorrect.isOn }))
                Text("Apps that are already open may need a restart to notice.").font(.footnote).foregroundColor(.secondary)
            }
            PerformanceView(model: model)
            VStack(alignment: .leading, spacing: 6) {
                Text("Other").font(.headline)
                Toggle("Check for updates automatically", isOn: $model.checkUpdates)
                Button("Personal Dictionary & Excluded Apps…") { model.openLists?() }
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

// MARK: status

final class StatusModel: ObservableObject {
    @Published var text = ""
    var source: (() -> String)?
    var testUnderline: (() -> Void)?
    private var timer: Timer?
    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func stop() { timer?.invalidate(); timer = nil }
    func refresh() { text = source?() ?? "" }
}

struct StatusView: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                Text(model.text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Show Test Underline") { model.testUnderline?() }
                    .help("Draws a mark under the text before the caret (or at the mouse) for 4 seconds")
                Spacer()
                Button("Copy Diagnostics") {
                    model.refresh()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.text, forType: .string)
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(minWidth: 560, minHeight: 420)
    }
}

struct PerformanceView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Performance").font(.headline)
            Picker("", selection: Binding(
                get: { model.perf.presetId },
                set: { id in if let p = Settings.Perf.presets.first(where: { $0.0 == id }) { model.perf = p.2 } })) {
                ForEach(Settings.Perf.presets, id: \.0) { Text($0.1).tag($0.0) }
                if model.perf.presetId == "custom" { Text("Custom").tag("custom") }
            }.pickerStyle(.segmented).labelsHidden()
            HStack {
                Text("Re-check after a pause of")
                Slider(value: $model.perf.idleSecs, in: 0.2...3, step: 0.1)
                Text(String(format: "%.1f s", model.perf.idleSecs)).monospacedDigit().frame(width: 44, alignment: .trailing)
            }
            HStack {
                Toggle("Also re-check while typing, every", isOn: Binding(
                    get: { model.perf.everyWords > 0 }, set: { model.perf.everyWords = $0 ? 3 : 0 }))
                Stepper("\(max(1, model.perf.everyWords)) words", value: Binding(
                    get: { max(1, model.perf.everyWords) }, set: { model.perf.everyWords = $0 }), in: 1...10)
                    .disabled(model.perf.everyWords == 0)
            }
            Picker("Check", selection: $model.perf.wholeField) {
                Text("Sentences near the cursor").tag(false)
                Text("The whole text box").tag(true)
            }
            Toggle("Let words near a sentence's end see the next sentence too", isOn: $model.perf.nextSentence)
            HStack {
                Text("Context the model reads")
                Slider(value: Binding(get: { Double(model.perf.ctxTokens) }, set: { model.perf.ctxTokens = Int($0) }), in: 64...1024, step: 64)
                Text("\(model.perf.ctxTokens) tokens").monospacedDigit().frame(width: 84, alignment: .trailing)
            }
            Text("Tokens of text before each word the model takes into account (about \(model.perf.ctxTokens * 4) characters). The m2 model was trained on 1024; more context costs more time per word, shown below. Heavier settings also check more often and more of the text. Checks never hold up typing: the next key cancels them.")
                .font(.footnote).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(model.usage).font(.system(size: 11, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: dictionary + excluded apps

final class ListsModel: ObservableObject {
    let user: UserData
    @Published var words: [String] = []
    @Published var apps: [String] = []
    init(user: UserData) { self.user = user; reload() }
    func reload() { words = user.all.sorted { $0.lowercased() < $1.lowercased() }; apps = Settings.shared.excluded }
}

struct ListsView: View {
    @ObservedObject var model: ListsModel
    @State private var newWord = ""
    @State private var newApp = ""
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading) {
            Picker("", selection: $tab) {
                Text("Personal dictionary").tag(0)
                Text("Excluded apps").tag(1)
            }.pickerStyle(.segmented).labelsHidden()
            if tab == 0 {
                Text("Words here are never corrected. Undoing a correction of a word adds it.").font(.footnote).foregroundColor(.secondary)
                List {
                    ForEach(model.words, id: \.self) { w in
                        HStack { Text(w); Spacer(); Button("Remove") { model.user.remove(w); model.reload() }.buttonStyle(.borderless) }
                    }
                }
                HStack {
                    TextField("Add a word", text: $newWord).onSubmit(addWord)
                    Button("Add", action: addWord).disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                Text("No corrections in these apps (bundle IDs; a trailing dot matches a whole family).").font(.footnote).foregroundColor(.secondary)
                List {
                    ForEach(model.apps, id: \.self) { a in
                        HStack {
                            Text(a).font(.system(.body, design: .monospaced))
                            Spacer()
                            Button("Remove") { Settings.shared.setExcluded(model.apps.filter { $0 != a }); model.reload() }.buttonStyle(.borderless)
                        }
                    }
                }
                HStack {
                    TextField("com.example.App", text: $newApp).onSubmit(addApp)
                    Button("Add", action: addApp).disabled(newApp.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Reset to defaults") { Settings.shared.setExcluded(Settings.defaultExcluded); model.reload() }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 460, minHeight: 420)
    }

    private func addWord() {
        let w = newWord.trimmingCharacters(in: .whitespaces)
        if model.user.add(w) { newWord = "" }
        model.reload()
    }

    private func addApp() {
        let a = newApp.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty else { return }
        if !model.apps.contains(a) { Settings.shared.setExcluded(model.apps + [a]) }
        newApp = ""
        model.reload()
    }
}

func makeWindow<V: View>(_ title: String, _ view: V) -> NSWindow {
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420), styleMask: [.titled, .closable, .resizable],
                     backing: .buffered, defer: false)
    w.title = title
    w.contentView = NSHostingView(rootView: view)
    w.isReleasedWhenClosed = false
    w.center()
    return w
}
