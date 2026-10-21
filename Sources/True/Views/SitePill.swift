import SwiftUI
import AppKit

/// The Mac-side mirror of `SiteService`: what the pane pills show.
@MainActor @Observable
final class SiteModel {
    static let shared: SiteModel = {
        let m = SiteModel()
        SiteService.shared.onChange = { list in DispatchQueue.main.async { SiteModel.shared.sites = list } }
        m.sites = SiteService.shared.snapshot()
        return m
    }()
    var sites: [SiteInfo] = []
    func sites(in pane: UUID) -> [SiteInfo] { sites.filter { $0.pane == pane } }

    /// Share / stop sharing off the main thread (tailscale can take a second).
    func toggle(_ s: SiteInfo) {
        Task.detached {
            _ = s.exposed ? SiteService.shared.unexpose(port: s.port) : SiteService.shared.expose(port: s.port)
        }
    }
}

/// "● 3000 → Phone" in a pane's corner, with a popover: URL, QR, Copy.
struct SitePill: View {
    let site: SiteInfo
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                Circle().fill(site.exposed ? Color.green : Theme.text.opacity(0.5)).frame(width: 5, height: 5)
                Text(site.exposed ? "\(String(site.port)) → Phone" : String(site.port))
            }
            .font(.caption.weight(.medium)).foregroundStyle(Theme.text)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Theme.hubCardFill, in: Capsule())
            .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(site.title.isEmpty ? "A web server in this pane" : site.title)
        .popover(isPresented: $open, arrowEdge: .top) { SitePopover(site: site) }
    }
}

private struct SitePopover: View {
    let site: SiteInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(site.title.isEmpty ? "localhost:\(String(site.port))" : site.title).font(.headline).lineLimit(1)
            if let url = site.url, site.exposed {
                if let qr = RemoteAccess.qr(url, side: 150) { Image(nsImage: qr).interpolation(.none).frame(width: 150, height: 150) }
                Text(url).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2)
                if let f = site.hostFix {
                    Text("\(f.framework) blocks this address. Add:").font(.caption).foregroundStyle(.secondary)
                    Text(f.snippet).font(.caption.monospaced()).textSelection(.enabled)
                }
                HStack {
                    Button("Copy link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url, forType: .string) }
                    Button("Stop sharing") { SiteModel.shared.toggle(site) }
                }
            } else {
                Text("Open this on your iPhone through Tailscale.").font(.caption).foregroundStyle(.secondary)
                Button("Share to phone") { SiteModel.shared.toggle(site) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(14).frame(width: 220, alignment: .leading)
    }
}
