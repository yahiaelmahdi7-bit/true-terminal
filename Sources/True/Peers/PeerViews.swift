import SwiftUI
import AppKit

/// Plain words for a peer job's status, in the same voice as the rest of the Hub.
extension PeerStatus {
    var pillLabel: String {
        switch self {
        case .queued: return "Sending"
        case .accepted: return "Accepted"
        case .working: return "Working"
        case .needsYou: return "Needs them"
        case .idle: return "Idle"
        case .done: return "Done"
        case .failed: return "Failed"
        case .declined: return "Declined"
        }
    }
    var isLoud: Bool { self == .working || self == .failed || self == .needsYou }
}

private func peerElapsed(_ from: Date, to: Date? = nil) -> String {
    hubElapsed((to ?? Date()).timeIntervalSince(from))
}

/// Hub groups "Sent to peers" and "From peers". Hidden when there is nothing to show.
struct PeerJobsSection: View {
    @State private var sent: [SentJob] = []
    @State private var inbound: [InboundJob] = []
    @State private var sentDetail: SentJob?
    @State private var inboundDetail: InboundJob?

    var body: some View {
        Group {
            if !sent.isEmpty || !inbound.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if !inbound.isEmpty {
                            label("From peers")
                            ForEach(inbound) { j in inboundRow(j) }
                        }
                        if !sent.isEmpty {
                            label("Sent to peers")
                            ForEach(sent) { j in sentRow(j) }
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 8)
                }
                .frame(maxHeight: 230)
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .peersChanged)) { _ in reload() }
        .sheet(item: $sentDetail) { SentJobSheet(job: $0) }
        .sheet(item: $inboundDetail) { InboundJobSheet(job: $0) { inboundDetail = nil; reload() } }
    }

    private func reload() {
        let e = PeerService.engine
        let cutoff = Date().addingTimeInterval(-3 * 86400)
        sent = e.sentJobs().filter { !$0.status.isFinal || $0.updated > cutoff }.prefix(8).map { $0 }
        inbound = e.inboundJobs().filter { !$0.status.isFinal || ($0.finished ?? .distantPast) > cutoff }.prefix(8).map { $0 }
    }

    private func label(_ t: String) -> some View {
        Text(t).font(.callout.weight(.medium)).foregroundStyle(Theme.hubSecondary).padding(.horizontal, 4).padding(.top, 6)
    }

    private func pill(_ s: PeerStatus) -> some View {
        Text(s.pillLabel).font(.callout.weight(s.isLoud ? .semibold : .regular))
            .foregroundStyle(s.isLoud ? Theme.text : Theme.hubSecondary).lineLimit(1)
    }

    private func sentRow(_ j: SentJob) -> some View {
        HubRowFrame {
            HStack(spacing: 12) {
                Image(systemName: "paperplane").frame(width: 32).foregroundStyle(Theme.hubSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(j.title).font(.body).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.tail)
                    Text("\(j.peerLabel) · \(peerElapsed(j.created, to: j.status.isFinal ? j.updated : nil))")
                        .font(.callout).foregroundStyle(Theme.hubSecondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                pill(j.status)
            }
        }
        .onTapGesture { sentDetail = j }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(j.title), sent to \(j.peerLabel), \(j.status.pillLabel)")
        .accessibilityAddTraits(.isButton)
    }

    private func inboundRow(_ j: InboundJob) -> some View {
        HubRowFrame {
            HStack(spacing: 12) {
                Image(systemName: "tray.and.arrow.down").frame(width: 32).foregroundStyle(Theme.hubSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(j.req.title).font(.body).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.tail)
                    Text("\(j.peerLabel) · \(peerElapsed(j.received, to: j.finished))")
                        .font(.callout).foregroundStyle(Theme.hubSecondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if !j.flags.isEmpty {
                    Label("\(j.flags.count)", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(Theme.text).help(j.flags.joined(separator: "\n"))
                }
                if j.status == .queued && j.inboundMode == .ask {
                    Button("Decline") { PeerService.engine.decline(j.id) }.buttonStyle(.plain).foregroundStyle(Theme.hubSecondary)
                    Button("Accept") { PeerService.engine.accept(j.id) }.buttonStyle(.plain).fontWeight(.semibold)
                } else {
                    pill(j.status)
                }
            }
        }
        .onTapGesture { inboundDetail = j }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(j.req.title), from \(j.peerLabel), \(j.status.pillLabel)")
        .accessibilityAddTraits(.isButton)
    }
}

/// What came back from the friend: result text, the branch, and the one command to fetch it.
struct SentJobSheet: View {
    let job: SentJob
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var tick = 0
    @State private var sayText = ""
    @State private var sayNote: String?

    var body: some View {
        let _ = tick                               // a peersChanged bump re-reads the live job and its activity
        let live = PeerService.engine.result(jobId: job.jobId) ?? job
        let items = PeerService.engine.activity(jobId: job.jobId, last: 200)
        VStack(alignment: .leading, spacing: 12) {
            Text(live.title).font(.title3.weight(.semibold))
            Text("\(live.peerLabel) · \(live.status.pillLabel)\(live.note.isEmpty ? "" : " · \(live.note)")")
                .font(.callout).foregroundStyle(.secondary)
            if let branch = live.branch {
                let cmd = PeerNaming.fetchCommand(branch: branch)
                Text(cmd).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                Button(copied ? "Copied" : "Copy fetch command") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cmd, forType: .string); copied = true
                }
            }
            ScrollView {
                Text(live.result?.isEmpty == false ? live.result! : "No result yet.")
                    .font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 100)
            if !items.isEmpty {
                Text("Live activity").font(.callout.weight(.semibold))
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                                Text("\(it.kind == .nack ? "✕" : "·") \(it.text)").font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(it.kind == .nack ? Color.red : Color.primary).id(i)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                    .onChange(of: items.count) { _, n in proxy.scrollTo(n - 1) }
                }
                .frame(minHeight: 110, maxHeight: 150)
            }
            if !live.status.isFinal {
                HStack {
                    TextField("Say to \(live.peerLabel)…", text: $sayText).textFieldStyle(.roundedBorder).onSubmit(send)
                    Button("Send", action: send).keyboardShortcut(.return, modifiers: .command).disabled(sayText.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Stop", role: .destructive) { sayNote = describe(PeerService.engine.stopJob(jobId: job.jobId), ok: "Asked \(live.peerLabel) to stop.") }
                }
                if let sayNote { Text(sayNote).font(.caption).foregroundStyle(.secondary) }
            }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(20).frame(width: 520, height: 560)
        .onReceive(NotificationCenter.default.publisher(for: .peersChanged)) { _ in tick += 1 }
    }

    private func send() {
        let t = sayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        sayNote = describe(PeerService.engine.say(jobId: job.jobId, text: t), ok: nil)
        if sayNote == nil { sayText = "" }
    }

    private func describe(_ r: Result<Void, PeerError>, ok: String?) -> String? {
        switch r {
        case .success: return ok
        case .failure(let e): if case .invalid(let m) = e { return m }; return "Couldn't do that"
        }
    }
}

/// The receiver's view of one job. In ask mode this is the Accept sheet, with the screening flags up top.
struct InboundJobSheet: View {
    let job: InboundJob
    let onDone: () -> Void

    var body: some View {
        let waiting = job.status == .queued && job.inboundMode == .ask
        VStack(alignment: .leading, spacing: 12) {
            Text(job.req.title).font(.title3.weight(.semibold))
            Text("From \(job.peerLabel)\(job.req.hasRepo ? " · \(job.req.repo)" : "") · \(job.status.pillLabel)").font(.callout).foregroundStyle(.secondary)
            if !job.flags.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Looks like it may be trying to steer Claude", systemImage: "exclamationmark.triangle").font(.callout.weight(.semibold))
                    ForEach(job.flags, id: \.self) { Text("• \($0)").font(.callout) }
                }
            }
            ScrollView {
                Text(String(job.req.brief.prefix(4000))).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 160)
            HStack {
                Spacer()
                if waiting {
                    Button("Decline") { PeerService.engine.decline(job.id); onDone() }
                    Button("Accept") { PeerService.engine.accept(job.id); onDone() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Close") { onDone() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(20).frame(width: 520, height: 420)
    }
}

@MainActor
final class PeersWindow {
    static let shared = PeersWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Peers"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: PeersView())
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct PeersView: View {
    @State private var mode = PeerInboundMode.current
    @State private var inviteText: String?
    @State private var copied = false
    @State private var links: [PeerLink] = []
    @State private var connected = false
    @State private var wanted = false
    @State private var paired: String?
    @State private var addInvite = ""
    @State private var addLabel = ""
    @State private var addNote: String?
    @State private var relayURL = PeerRelay.url
    @State private var showAdvanced = false
    @State private var steering = PeerSettings.steering
    @State private var chatOn = PeerSettings.chat
    @State private var share = PeerSettings.share
    @State private var dirs = PeerSettings.allowedDirs
    @State private var dirNote: String?

    var body: some View {
        ScrollView { content }
            .frame(width: 460, height: 640, alignment: .topLeading)
            .onAppear(perform: reload)
            .onReceive(NotificationCenter.default.publisher(for: .peersChanged)) { _ in reload() }
    }

    private func reload() {
        let e = PeerService.engine
        links = e.peerLinks(); connected = e.isConnected; wanted = e.wantsRelay; paired = e.lastPaired
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            if wanted {
                Text(connected ? "Connected" : "Offline — retrying").font(.callout).foregroundStyle(.secondary)
            }
            if let paired { Text("Paired with \(paired)").font(.callout.weight(.semibold)) }
            Text("Jobs from peers").font(.headline)
            Picker("", selection: Binding(get: { mode }, set: { mode = $0; PeerInboundMode.current = $0 })) {
                Text("Run at once, no prompts").tag(PeerInboundMode.bypass)
                Text("Run on auto").tag(PeerInboundMode.auto)
                Text("Ask me first").tag(PeerInboundMode.ask)
            }
            .pickerStyle(.radioGroup).labelsHidden()
            Text("Applies to jobs a paired friend sends this Mac.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Directories peers may work in").font(.headline)
            if dirs.isEmpty { Text("None. Peers can only send repo and no-project jobs.").font(.caption).foregroundStyle(.secondary) }
            ForEach(dirs, id: \.self) { d in
                HStack {
                    Text(d).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Remove") { dirs.removeAll { $0 == d }; PeerSettings.allowedDirs = dirs }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Add folder…", action: addDir)
                if let dirNote { Text(dirNote).font(.caption).foregroundStyle(.secondary) }
            }
            Toggle("Let peers send follow-ups", isOn: Binding(get: { steering }, set: { steering = $0; PeerSettings.steering = $0 }))
            Toggle("Let peers chat with my agents", isOn: Binding(get: { chatOn }, set: { chatOn = $0; PeerSettings.chat = $0 }))
            Picker("Share with the sender", selection: Binding(get: { share }, set: { share = $0; PeerSettings.share = $0 })) {
                Text("Status only").tag(PeerShare.status)
                Text("Activity").tag(PeerShare.activity)
            }
            .pickerStyle(.segmented)
            Divider()
            Text("Invite a peer").font(.headline)
            if let inviteText {
                Text(inviteText).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(4)
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(inviteText, forType: .string); copied = true
                }
                Text("Send this to one person. It works once, for 24 hours.").font(.caption).foregroundStyle(.secondary)
            }
            Button(inviteText == nil ? "Invite" : "New invite") { inviteText = PeerService.engine.invite(); copied = false; reload() }
            Divider()
            Text("Add a peer").font(.headline)
            TextField("Paste their invite", text: $addInvite).textFieldStyle(.roundedBorder)
            TextField("What you call them", text: $addLabel).textFieldStyle(.roundedBorder)
            HStack {
                Button("Add") { add() }.disabled(addInvite.isEmpty || addLabel.isEmpty)
                if let addNote { Text(addNote).font(.callout).foregroundStyle(.secondary) }
            }
            Divider()
            Text("Your peers").font(.headline)
            if links.isEmpty { Text("Nobody yet.").foregroundStyle(.secondary) }
            ForEach(links, id: \.mailboxId) { l in
                HStack {
                    VStack(alignment: .leading) {
                        Text(l.label)
                        if !l.confirmed { Text("Waiting for them to accept").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button("Revoke", role: .destructive) { PeerService.engine.revoke(mailboxId: l.mailboxId) }
                }
            }
            Divider()
            Button("Stop all peer jobs", role: .destructive) { PeerService.engine.stopAll() }
            Text("Ends every job running for a peer and declines the waiting ones.").font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Relay address", text: $relayURL).textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Use this relay") { PeerRelay.url = relayURL; relayURL = PeerRelay.url; PeerService.relay.reload() }
                        Button("Reset") { PeerRelay.url = ""; relayURL = PeerRelay.url; PeerService.relay.reload() }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(20).frame(width: 460, alignment: .topLeading)
    }

    private func addDir() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false; p.prompt = "Allow"
        guard p.runModal() == .OK, let url = p.url else { return }
        let path = url.resolvingSymlinksInPath().path
        guard case .success = PeerDirs.resolve(path: path, allowed: [path]) else { dirNote = "That folder is too broad to allow."; return }
        dirNote = nil
        if !dirs.contains(path) { dirs.append(path); PeerSettings.allowedDirs = dirs }
    }

    private func add() {
        let r = PeerService.engine.pairWithInvite(addInvite, label: addLabel)
        switch r {
        case .success: addNote = "Asked \(addLabel) to pair."; addInvite = ""; addLabel = ""
        case .failure(let e): if case .invalid(let m) = e { addNote = m }
        }
        reload()
    }
}
