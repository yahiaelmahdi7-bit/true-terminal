import SwiftUI
import AVFoundation
import AppKit

@MainActor
final class DictationSetupModel: ObservableObject {
    enum Mic { case notDetermined, denied, authorized }

    @Published var engineReady = false
    @Published var brewPath: String?
    @Published var installing = false
    @Published var installLine = ""
    @Published var engineError = ""
    @Published var modelReady = false
    @Published var downloading = false
    @Published var progress = 0.0
    @Published var modelError = ""
    @Published var mic = Mic.notDetermined
    @Published var choice = WhisperModel.recommended.file

    private var installer: BrewInstaller?
    private var downloader: ModelDownloader?

    var selected: WhisperModel { WhisperModel.all.first { $0.file == choice } ?? .recommended }

    func refresh() {
        let d = UserDefaults.standard
        engineReady = DictationEngine.resolve(userPath: d.string(forKey: DictationSettings.binaryKey) ?? "") != nil
        brewPath = DictationEngine.brew()
        modelReady = DictationModels.resolve(userPath: d.string(forKey: DictationSettings.modelKey) ?? "") != nil
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = .authorized
        case .notDetermined: mic = .notDetermined
        default: mic = .denied
        }
    }

    func installWhisper() {
        guard let brew = brewPath, !installing else { return }
        let i = BrewInstaller(brew: brew)
        installer = i; installing = true; installLine = "Starting…"; engineError = ""
        Task {
            let r = await i.run { line in Task { @MainActor in self.installLine = line } }
            installing = false; installer = nil
            refresh()
            if !engineReady { engineError = r.ok ? "Install finished but whisper-cli was not found." : r.errorLine }
        }
    }

    func cancelInstall() { installer?.cancel() }

    func copyBrewCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("brew install whisper-cpp", forType: .string)
    }

    func download() {
        guard !downloading else { return }
        let d = ModelDownloader(model: selected)
        downloader = d; downloading = true; progress = 0; modelError = ""
        Task {
            do {
                _ = try await d.run { p in Task { @MainActor in self.progress = p } }
            } catch let e as DownloadError where e == .cancelled {
            } catch {
                modelError = error.localizedDescription
            }
            downloading = false; downloader = nil
            refresh()
        }
    }

    func cancelDownload() { downloader?.cancel() }

    func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in Task { @MainActor in self.refresh() } }
    }

    func openPrivacySettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(u) }
    }
}

/// Settings > Dictation "Setup": three rows, each a checkmark or one action.
struct DictationSetupRows: View {
    @StateObject private var m = DictationSetupModel()

    var body: some View {
        Group {
            engineRow
            modelRow
            micRow
        }
        .onAppear { m.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in m.refresh() }
    }

    private var ready: some View { Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary) }

    @ViewBuilder private var engineRow: some View {
        LabeledContent("Whisper engine") {
            if m.engineReady { ready }
            else if m.installing { Button("Cancel") { m.cancelInstall() }.controlSize(.large) }
            else if m.brewPath != nil { Button("Install Whisper") { m.installWhisper() }.controlSize(.large) }
            else { Button("Check again") { m.refresh() }.controlSize(.large) }
        }
        if m.installing {
            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text(m.installLine).lineLimit(1).truncationMode(.head) }
                .font(.caption).foregroundStyle(.secondary)
        } else if !m.engineReady && m.brewPath == nil {
            Text("Dictation needs Whisper, installed with Homebrew. Install Homebrew from brew.sh, then press Check again.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("brew install whisper-cpp") {
                Button("Copy command") { m.copyBrewCommand() }.controlSize(.large)
            }
        }
        if !m.engineError.isEmpty { Text(m.engineError).font(.caption).foregroundStyle(.secondary) }
    }

    @ViewBuilder private var modelRow: some View {
        if m.modelReady {
            LabeledContent("Speech model") { ready }
        } else {
            Picker("Speech model", selection: $m.choice) {
                ForEach(WhisperModel.all) { Text("\($0.title) (\($0.sizeLabel))").tag($0.file) }
            }
            .disabled(m.downloading)
            LabeledContent(m.downloading ? "Downloading \(Int(m.progress * 100))%" : m.selected.file) {
                if m.downloading { Button("Cancel") { m.cancelDownload() }.controlSize(.large) }
                else { Button("Download") { m.download() }.controlSize(.large) }
            }
            if m.downloading { ProgressView(value: m.progress) }
            if !m.modelError.isEmpty { Text(m.modelError).font(.caption).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private var micRow: some View {
        LabeledContent("Microphone") {
            switch m.mic {
            case .authorized: ready
            case .notDetermined: Button("Allow microphone") { m.requestMic() }.controlSize(.large)
            case .denied: Button("Open Privacy Settings") { m.openPrivacySettings() }.controlSize(.large)
            }
        }
    }
}
