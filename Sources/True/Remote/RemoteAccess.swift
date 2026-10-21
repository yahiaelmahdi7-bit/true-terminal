import Foundation
import AppKit
import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import Observation
import TrueRemoteClient

/// Owner of the Remote Access server and its settings. Off by default; the toggle lives in UserDefaults.
@MainActor
@Observable
final class RemoteAccess {
    static let shared = RemoteAccess()
    static let enabledKey = "remote.enabled"
    static let shareClipboardKey = "remote.shareClipboard"
    nonisolated static let loginOverrideKey = "remote.allowedLogin"
    nonisolated static let tailscale = "/opt/homebrew/bin/tailscale"
    static let httpsPort = RemoteAuth.httpsPort   // what Claude exposes with `tailscale serve --https=8444 http://127.0.0.1:8801`

    private(set) var enabled = UserDefaults.standard.bool(forKey: RemoteAccess.enabledKey)
    private(set) var listening = false
    private(set) var shareClipboard = UserDefaults.standard.bool(forKey: RemoteAccess.shareClipboardKey)   // default off
    private(set) var code: String?
    private(set) var codeExpiry: Date?
    private(set) var devices: [PairedDevice] = []
    private(set) var dnsName: String?
    private(set) var selfLogin: String?
    private(set) var tailscaleNote: String?

    /// "Show a pairing card when my iPhone is nearby" (default ON): gates Bluetooth advertising while Remote Access is on.
    private(set) var nearbyCard = UserDefaults.standard.object(forKey: NearbyHost.cardKey) as? Bool ?? true
    /// Where a phone's Bluetooth hello goes. Production: the floating card; tests replace it.
    @ObservationIgnored var onNearbyHello: (NearbyPairing.Hello) -> Void = {
        NearbyPairCardController.shared.present(phoneName: $0.name, phoneID: $0.id)
    }
    @ObservationIgnored lazy var nearby = NearbyHost(
        advertiser: CoreBluetoothAdvertiser(),
        computerName: { Host.current().localizedName ?? ProcessInfo.processInfo.hostName },
        address: { [weak self] in self?.dnsName.map { "\($0):\(RemoteAccess.httpsPort)" } },
        onHello: { [weak self] in self?.onNearbyHello($0) })
    @ObservationIgnored let codes = PairingCodes()
    @ObservationIgnored let deviceStore = DeviceStore()
    @ObservationIgnored private var server: RemoteServer?
    nonisolated static let sharedLoginCache = LoginCache()
    nonisolated static func currentDNS() -> String? { sharedLoginCache.dns() }
    @ObservationIgnored private var loginCache: LoginCache { Self.sharedLoginCache }

    var url: String? { dnsName.map { "https://\($0):\(Self.httpsPort)" } }
    var allowedLoginOverride: String {
        get { UserDefaults.standard.string(forKey: Self.loginOverrideKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: Self.loginOverrideKey) }
    }

    /// Launch side effect, justified: it only runs if the user turned Remote Access on (default off).
    func startIfEnabled() { if enabled { start() }; syncClipboardShare(); syncNearby() }

    func setNearbyCard(_ on: Bool) {
        nearbyCard = on
        UserDefaults.standard.set(on, forKey: NearbyHost.cardKey)
        syncNearby()
    }

    /// Bluetooth advertises only while Remote Access is on AND the card toggle is on.
    func syncNearby() { nearby.sync(remoteOn: enabled, cardOn: nearbyCard) }

    func setShareClipboard(_ on: Bool) {
        shareClipboard = on
        UserDefaults.standard.set(on, forKey: Self.shareClipboardKey)
        syncClipboardShare()
    }

    /// The pasteboard timer runs only while Remote Access is on AND the user opted in.
    private func syncClipboardShare() {
        if enabled && shareClipboard { ClipboardShare.shared.start() } else { ClipboardShare.shared.stop() }
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on { start(); refreshTailnet(); newCode() } else { stop() }
        syncClipboardShare()
        syncNearby()
    }

    private func start(attempt: Int = 0) {
        if server == nil {
            let cache = loginCache
            server = RemoteServer(backend: RemoteBackendLive(), codes: codes, devices: deviceStore, allowedLogin: {
                let o = UserDefaults.standard.string(forKey: RemoteAccess.loginOverrideKey) ?? ""
                return o.isEmpty ? cache.login() : o
            }, dnsName: { cache.dns() }, sites: SiteService.shared, browser: BrowserHub.shared)
        }
        listening = server?.start() ?? false
        if listening { _ = SiteModel.shared; SiteService.shared.start() }
        devices = deviceStore.all
        // The previous copy of the app may still hold 127.0.0.1:8801 for a moment after a restart; retry
        // rather than leave the phone with a dead page until the toggle is flipped by hand.
        if !listening, enabled, attempt < 15 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.enabled, !self.listening else { return }
                self.start(attempt: attempt + 1)
            }
        }
    }

    private func stop() {
        server?.stop(); server = nil; listening = false
        SiteService.shared.stop()
        codes.revokeCode(); code = nil; codeExpiry = nil
    }

    func newCode() {
        code = codes.issue(); codeExpiry = codes.expiry()
    }

    func revoke(_ d: PairedDevice) { deviceStore.revoke(d.id); server?.disconnect(device: d.id); devices = deviceStore.all }
    func reloadDevices() { devices = deviceStore.all }

    /// A paired device named "Shortcut" for the iOS share sheet. The raw token is returned once; only its hash is stored.
    func createShortcutToken() -> String {
        let t = deviceStore.pair(label: "Shortcut", scope: .dropOnly)
        devices = deviceStore.all
        return t
    }

    /// Reads the MagicDNS name and login from `tailscale status --json` at runtime (never at build time).
    func refreshTailnet() {
        let cache = loginCache
        Task.detached {
            let info = cache.refresh()
            await MainActor.run {
                RemoteAccess.shared.dnsName = info?.dns
                RemoteAccess.shared.selfLogin = info?.login
                RemoteAccess.shared.tailscaleNote = info == nil ? "Tailscale not reachable — open Tailscale and sign in." : nil
            }
        }
    }

    /// Cached `tailscale status` Self identity; the server asks it on every request, so it caches for 60 s.
    final class LoginCache: @unchecked Sendable {
        private let lock = NSLock()
        private var cached: (dns: String?, login: String?, at: Date)?

        func login() -> String? {
            lock.lock(); let c = cached; lock.unlock()
            if let c, Date().timeIntervalSince(c.at) < 60 { return c.login }
            return refresh()?.login
        }

        /// Self.DNSName for the exact Host/Origin checks; same 60 s cache.
        func dns() -> String? {
            lock.lock(); let c = cached; lock.unlock()
            if let c, Date().timeIntervalSince(c.at) < 60 { return c.dns }
            return refresh()?.dns
        }

        @discardableResult
        func refresh() -> (dns: String?, login: String?)? {
            guard let data = Self.run(RemoteAccess.tailscale, ["status", "--json"]),
                  let info = Self.parse(data) else { return nil }
            lock.lock(); cached = (info.dns, info.login, Date()); lock.unlock()
            return info
        }

        /// Self.DNSName (trailing dot dropped) and the login of Self.UserID.
        static func parse(_ data: Data) -> (dns: String?, login: String?)? {
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let me = root["Self"] as? [String: Any] else { return nil }
            var dns = me["DNSName"] as? String
            if dns?.hasSuffix(".") == true { dns?.removeLast() }
            var login: String?
            if let uid = me["UserID"] as? Int, let users = root["User"] as? [String: Any],
               let u = users[String(uid)] as? [String: Any] { login = u["LoginName"] as? String }
            return (dns, login)
        }

        private static func run(_ exe: String, _ args: [String]) -> Data? { Subprocess.run(exe, args) }
    }

    /// What the QR encodes: the address and (while one is live) the pairing code, as a `true://pair` link the phone parses.
    nonisolated static func pairLink(host: String, code: String?) -> String {
        var c = URLComponents()
        c.scheme = "true"; c.host = "pair"
        var items = [URLQueryItem(name: "host", value: host)]
        if let code { items.append(URLQueryItem(name: "code", value: code)) }
        c.queryItems = items
        // ':' is legal inside a query value; leave it readable so the QR stays small.
        return (c.string ?? "true://pair").replacingOccurrences(of: "%3A", with: ":")
    }

    static func qr(_ text: String, side: CGFloat = 180) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8); f.correctionLevel = "M"
        guard let out = f.outputImage else { return nil }
        let scale = side / out.extent.width
        let big = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: big)
        let img = NSImage(size: rep.size); img.addRepresentation(rep)
        return img
    }
}

@MainActor
final class RemoteAccessWindow {
    static let shared = RemoteAccessWindow()
    private var window: NSWindow?

    func show() {
        RemoteAccess.shared.reloadDevices()
        RemoteAccess.shared.refreshTailnet()
        if RemoteAccess.shared.enabled { RemoteAccess.shared.newCode() }   // a fresh code every time it is shown
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 720),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Remote Access"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: RemoteAccessView())
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct RemoteAccessView: View {
    @State private var remote = RemoteAccess.shared
    @State private var login = RemoteAccess.shared.allowedLoginOverride
    @State private var shortcutToken: String?
    @State private var copied = false

    var body: some View {
        ScrollView { content }
            .frame(width: 440, height: 720, alignment: .topLeading)
            .onAppear { remote.reloadDevices() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Allow access from my phone (tailnet only)", isOn: Binding(get: { remote.enabled },
                                                                          set: { remote.setEnabled($0) }))
                .toggleStyle(.switch)
            Text(statusLine).font(.callout).foregroundStyle(.secondary)
            if remote.enabled {
                Divider()
                if let url = remote.url {
                    Text(url).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    if let dns = remote.dnsName,
                       let img = RemoteAccess.qr(RemoteAccess.pairLink(host: "\(dns):\(RemoteAccess.httpsPort)", code: remote.code)) {
                        Image(nsImage: img).interpolation(.none).frame(width: 180, height: 180)
                            .accessibilityLabel("QR code with the Remote Access address and pairing code")
                        Text("Scan with True on your iPhone — it fills the address and code for you.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(remote.tailscaleNote ?? "Looking up this Mac's tailnet name…").foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(remote.code ?? "——————").font(.system(size: 30, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(expiryText(ctx.date)).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("New code") { remote.newCode() }
                }
                Text("Pairing code — type it on the phone the first time. Single use, expires in 5 minutes.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Toggle("Show a pairing card when my iPhone is nearby", isOn: Binding(get: { remote.nearbyCard },
                                                                                  set: { remote.setNearbyCard($0) }))
                    .toggleStyle(.switch)
                Text("Bluetooth is used only to notice the phone. It never carries the pairing code.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                Text("Paired phones").font(.headline)
                if remote.devices.isEmpty { Text("None yet.").foregroundStyle(.secondary) }
                ForEach(remote.devices) { d in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(d.scope == .dropOnly ? "\(d.label) · send only" : d.label)
                            Text("last seen \(d.lastSeen.formatted(.relative(presentation: .named)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Revoke", role: .destructive) { remote.revoke(d) }
                    }
                }
                Divider()
                Toggle("Share my Mac's copies with paired phones", isOn: Binding(get: { remote.shareClipboard },
                                                                                set: { remote.setShareClipboard($0) }))
                    .toggleStyle(.switch)
                Text("Text you copy on this Mac appears on the phone's Send tab (and lands on its clipboard if the phone allows). Passwords and concealed copies are never shared.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                HStack {
                    Text("Allowed login").font(.callout)
                    TextField(remote.selfLogin ?? "this Mac's Tailscale user", text: $login)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { remote.allowedLoginOverride = login }
                }
                Text("Blank = the Tailscale user signed in on this Mac. Anyone else is refused (403).")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                shortcutSection
            }
        }
        .padding(20)
        .frame(width: 440, alignment: .topLeading)
    }

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("iPhone Shortcut").font(.headline)
            Text("Adds “Send to True” to the iPhone share sheet. The token is a send-only device named “Shortcut” (it can only send files and text to this Mac) — revoke it above any time.")
                .font(.caption).foregroundStyle(.secondary)
            if let t = shortcutToken {
                Text(t).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                HStack {
                    Button(copied ? "Copied" : "Copy token") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        // Ask clipboard managers (nspasteboard.org convention) not to record the token.
                        pb.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
                        pb.setString(t, forType: .string)
                        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
                        copied = true
                    }
                    Button("Done") {
                        if NSPasteboard.general.string(forType: .string) == t { NSPasteboard.general.clearContents() }
                        shortcutToken = nil; copied = false
                    }
                }
                Text("Shown once — it can't be shown again.").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Create Shortcut token") { shortcutToken = remote.createShortcutToken() }
            }
            Text("1. Shortcuts app → New Shortcut → turn on “Show in Share Sheet”.\n2. Add “Get Contents of URL”: \(remote.url ?? "https://<this-mac>.ts.net:8444")/api/drop\n3. Method POST. Headers: Authorization = Bearer <token>, X-Filename = Name (the Shortcut Input’s Name).\n4. Request Body = File → Shortcut Input.")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private var statusLine: String {
        if !remote.enabled { return "Off. True is not listening." }
        return remote.listening ? "On — listening on 127.0.0.1:\(RemoteServer.port) (this Mac only; Tailscale carries it to your phone)."
                                : "On, but the port could not be opened (is 8801 in use?)."
    }

    private func expiryText(_ now: Date) -> String {
        if remote.codes.isBurned { return "Code burned — show a new one" }
        guard let e = remote.codeExpiry else { return "" }
        let s = Int(e.timeIntervalSince(now))
        return s > 0 ? String(format: "expires in %d:%02d", s / 60, s % 60) : "expired — tap New code"
    }
}
