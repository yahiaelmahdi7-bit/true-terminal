import SwiftUI
import AppKit
import Observation
import TrueRemoteClient

/// One card per phone per 5 minutes, and never more than one card every few seconds overall, so a stranger's
/// phone cycling identifiers cannot turn the corner of the screen into a slot machine.
struct NearbyCardRateLimit {
    static let perPhone: TimeInterval = 300
    static let anyPhone: TimeInterval = 5
    private var last: [String: Date] = [:]
    private var lastAny = Date.distantPast

    /// True (and remembered) if a card may be shown for this phone now.
    mutating func allow(id: String, now: Date) -> Bool {
        if let t = last[id], now.timeIntervalSince(t) < Self.perPhone { return false }
        if now.timeIntervalSince(lastAny) < Self.anyPhone { return false }
        last[id] = now; lastAny = now
        last = last.filter { now.timeIntervalSince($0.value) < Self.perPhone }
        return true
    }
}

/// The pairing card as a pure view, so a test can render it. The panel hosts it; nothing here touches RemoteAccess.
struct NearbyPairCardView: View {
    let macName: String
    let phoneName: String
    let qr: NSImage?
    let code: String?
    let paired: Bool
    var onDismiss: () -> Void = {}

    var body: some View {
        VStack(spacing: 12) {
            if paired {
                Spacer()
                Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(.tint)
                    .symbolEffect(.bounce, value: paired)
                Text("Paired with \(phoneName)").font(.headline).lineLimit(2).multilineTextAlignment(.center)
                Text("From now on it works from anywhere.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else {
                VStack(spacing: 2) {
                    Text(macName).font(.headline).lineLimit(1)
                    Text("\(phoneName) wants to pair").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Group {
                    if let qr {
                        Image(nsImage: qr).interpolation(.none).resizable().frame(width: 180, height: 180)
                            .padding(10).background(.white, in: .rect(cornerRadius: 12, style: .continuous))
                            .accessibilityLabel("QR code with this Mac's address and the pairing code")
                    } else {
                        ProgressView().frame(width: 200, height: 200)
                    }
                }
                Text(code ?? "——————")
                    .font(.system(size: 30, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                Text("Scan with True on your iPhone, or type the code.").font(.caption).foregroundStyle(.secondary)
                Group {
                    if #available(macOS 26.0, *) {
                        Button("Dismiss", action: onDismiss).buttonStyle(.glass)
                    } else {
                        Button("Dismiss", action: onDismiss).buttonStyle(.bordered)
                    }
                }.controlSize(.regular)
            }
        }
        .padding(16)
        .frame(width: NearbyPairCardController.size.width, height: NearbyPairCardController.size.height, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor), in: .rect(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.separator))
    }
}

/// Non-activating, never key, every Space, floating: the same panel recipe as `TrayPanel`.
final class NearbyPairPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: NearbyPairCardController.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .none
    }
}

/// What the controller reads from and asks of Remote Access. Production wires `RemoteAccess.shared`; tests wire fakes.
struct NearbyCardSource {
    var macName: () -> String
    var newCode: () -> Void
    var code: () -> String?
    var address: () -> String?
    /// Re-reads the paired list (the server pairs on its own thread) and returns its count.
    var deviceCount: () -> Int
    var phonePaired: () -> Void

    @MainActor static var live: NearbyCardSource {
        let r = RemoteAccess.shared
        return NearbyCardSource(
            macName: { Host.current().localizedName ?? ProcessInfo.processInfo.hostName },
            newCode: { r.refreshTailnet(); r.newCode() },
            code: { r.code },
            address: { r.dnsName.map { "\($0):\(RemoteAccess.httpsPort)" } },
            deviceCount: { r.reloadDevices(); return r.devices.count },
            phonePaired: { r.nearby.notifyPaired() })
    }
}

/// Presents the card when a phone says hello, keeps its code fresh, flips it to "Paired", and hides it.
@MainActor @Observable
final class NearbyPairCardController {
    static let shared = NearbyPairCardController(source: .live)
    static let size = CGSize(width: 292, height: 372)
    static let inset: CGFloat = 12

    private(set) var phoneName = ""
    private(set) var phoneID = ""
    private(set) var visible = false
    private(set) var paired = false

    var macName: String { source.macName() }
    var code: String? { source.code() }
    var qrImage: NSImage? {
        guard let host = source.address() else { return nil }
        return RemoteAccess.qr(RemoteAccess.pairLink(host: host, code: source.code()), side: 180)
    }

    @ObservationIgnored private let source: NearbyCardSource
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let autoHide: Duration
    @ObservationIgnored private let pairedHide: Duration
    @ObservationIgnored private let usesPanel: Bool
    @ObservationIgnored private var limit = NearbyCardRateLimit()
    @ObservationIgnored private var panel: NearbyPairPanel?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var devicesAtShow = 0
    @ObservationIgnored private var lastCode: String?

    init(source: NearbyCardSource, now: @escaping () -> Date = Date.init,
         autoHide: Duration = .seconds(60), pairedHide: Duration = .seconds(1.5), usesPanel: Bool = true) {
        self.source = source; self.now = now; self.autoHide = autoHide; self.pairedHide = pairedHide
        self.usesPanel = usesPanel
    }

    /// A phone said hello over Bluetooth. Returns whether a card was shown (false = rate-limited).
    @discardableResult
    func present(phoneName: String, phoneID: String) -> Bool {
        guard limit.allow(id: phoneID, now: now()) else { return false }
        self.phoneName = String(phoneName.prefix(40)); self.phoneID = phoneID
        paired = false
        source.newCode()   // a fresh single-use code every time the card shows, like opening the sheet
        devicesAtShow = source.deviceCount()
        lastCode = source.code()
        visible = true
        showPanel()
        scheduleHide(after: autoHide)
        startPolling()
        return true
    }

    func dismiss() {
        hideTask?.cancel(); pollTask?.cancel()
        visible = false; paired = false
        panel?.orderOut(nil)
    }

    /// Once a second while up: did a phone pair (by scanning or typing)? Did the code change?
    func tick() {
        guard visible, !paired else { return }
        if source.deviceCount() > devicesAtShow {
            paired = true
            source.phonePaired()
            scheduleHide(after: pairedHide)
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.tick()
            }
        }
    }

    private func scheduleHide(after d: Duration) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: d)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    // MARK: - Panel

    private func showPanel() {
        guard usesPanel else { return }
        if panel == nil {
            let p = NearbyPairPanel()
            let host = NSHostingView(rootView: NearbyPairCardRoot(controller: self))
            host.sizingOptions = []
            p.contentView = host
            panel = p
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let v = screen?.visibleFrame {
            let size = Self.size
            panel?.setFrame(NSRect(x: v.maxX - size.width - Self.inset, y: v.maxY - size.height - Self.inset,
                                   width: size.width, height: size.height), display: true)
        }
        panel?.orderFrontRegardless()
    }
}

private struct NearbyPairCardRoot: View {
    let controller: NearbyPairCardController
    var body: some View {
        NearbyPairCardView(macName: controller.macName, phoneName: controller.phoneName, qr: controller.qrImage,
                           code: controller.code, paired: controller.paired, onDismiss: { controller.dismiss() })
    }
}
