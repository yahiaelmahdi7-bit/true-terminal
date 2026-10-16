import SwiftUI

/// ⌘, — six settings, applied live to every open pane (EmbeddedTerminal.updateNSView).
struct SettingsView: View {
    @AppStorage(TerminalSettings.fontFamilyKey) private var family = TerminalSettings.systemMono
    @AppStorage(TerminalSettings.fontSizeKey) private var size = TerminalSettings.defaultFontSize
    @AppStorage(TerminalSettings.cursorKey) private var cursor = TerminalSettings.Cursor.steadyBlock.rawValue
    @AppStorage(TerminalSettings.scrollbackKey) private var scrollback = TerminalSettings.defaultScrollback
    @AppStorage(TerminalSettings.colorKey) private var color = TerminalSettings.defaultColor
    @AppStorage(TerminalSettings.inlineSuggestionsKey) private var inlineSuggestions = true
    @AppStorage(TerminalSettings.claudeAutostartKey) private var claudeAutostart = TerminalSettings.claudeAutostartDefault()
    @AppStorage(TerminalSettings.overseerKey) private var overseer = true
    @AppStorage(TerminalSettings.watcherKey) private var watcher = true

    var body: some View {
        Form {
            UpdateSettingsSection()
            Picker("Font", selection: $family) {
                Text("System Mono").tag(TerminalSettings.systemMono)
                Divider()
                ForEach(TerminalSettings.fixedPitchFamilies, id: \.self) { Text($0).tag($0) }
            }
            Stepper(value: $size, in: 9...32, step: 1) { Text("Size: \(Int(size)) pt") }
            Picker("Cursor", selection: $cursor) {
                ForEach(TerminalSettings.Cursor.allCases) { Text($0.label).tag($0.rawValue) }
            }
            Stepper(value: $scrollback, in: 500...100_000, step: 500) {
                Text("Scrollback: \(scrollback.formatted()) lines")
            }
            Toggle("Colour in terminals", isOn: $color)
            Toggle("Inline suggestions", isOn: $inlineSuggestions)
                .help("Grey ghost text from your history as you type in zsh; → or End accepts, ⌥→ takes one word. Applies to new panes.")
            Toggle("Start Claude in new tabs (skip permissions)", isOn: $claudeAutostart)
                .help("A new tab and a fresh launch open Claude with --dangerously-skip-permissions. Splits stay a plain shell.")
            Toggle("Overseer", isOn: $overseer)
                .help("After each Claude turn in a True pane, a judge reads what was asked and answered and shows a verdict. Needs a judging service, which this build does not include.")
                .onChange(of: overseer) { _, on in if !on { OverseerStore.shared.clearAll() } }
            Toggle("Watcher", isOn: $watcher)
                .help("Watches your builders, unpushed work and failed sessions, and proposes fixes in the Hub for you to approve. Needs a judging service, which this build does not include.")
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Auto-check and install-on-quit switches, "Check now", last-checked time. Shown only in a build that can update itself.
private struct UpdateSettingsSection: View {
    @AppStorage(UpdateLogic.autoKey) private var auto = true
    @AppStorage(UpdateLogic.installKey) private var install = true

    var body: some View {
        let updater = Updater.shared
        if updater.enabled {
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $auto)
                Toggle("Install updates automatically", isOn: $install)
                    .help("A downloaded, verified update is installed when you quit True.")
                LabeledContent(updater.status.isEmpty ? "Version \(updater.ownVersion)" : updater.status) {
                    Button("Check now") { Task { await updater.check(manual: true) } }.disabled(updater.checking)
                }
                if let last = updater.lastChecked {
                    LabeledContent("Last checked") { Text(last, format: .relative(presentation: .named)).foregroundStyle(.secondary) }
                }
            }
        }
    }
}
