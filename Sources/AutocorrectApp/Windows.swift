import AppKit
import ApplicationServices
import Engine
import SwiftUI

// MARK: onboarding (Accessibility permission)

final class PermissionModel: ObservableObject {
    @Published var trusted = AXIsProcessTrusted()
}

struct PermissionView: View {
    @ObservedObject var model: PermissionModel
    let openSettings: () -> Void
    let relaunch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Autocorrect needs Accessibility access").font(.title2).bold()
            Text("It watches what you type and fixes typos when you finish a word, using a small language model that runs on this Mac. Nothing you type leaves your computer.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Click **Open System Settings**.")
                Text("2. Turn on **Autocorrect** under Privacy & Security → Accessibility (add it with + if it isn't listed).")
                Text("3. Come back here. This window closes by itself once access is granted.")
            }
            Text("Tip: turn off macOS's own \"Correct spelling automatically\" (System Settings → Keyboard → Text Input → Edit) so the two don't fight.")
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
