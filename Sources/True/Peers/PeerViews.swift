import SwiftUI
import AppKit
@preconcurrency import UserNotifications

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
        case .paused: return "Paused"
        case .canceled: return "Canceled"
        }
    }
    var isLoud: Bool { self == .working || self == .failed || self == .needsYou }
}

/// Missions M1: the plain status wording shown beside a job (paused, canceled, needs-you with the reason).
enum PeerStatusText {
    /// H5: "2 h 10 m", "45 m", "less than a minute".
    static func age(_ secs: TimeInterval) -> String {
        let m = Int(max(0, secs) / 60)
        if m < 1 { return "less than a minute" }
        return m < 60 ? "\(m) m" : "\(m / 60) h \(m % 60) m"
    }
    /// H5: the sender's line while the other person hasn't pressed Accept.
    static func waitingForAccept(name: String, since: Date, now: Date = Date()) -> String {
        "waiting for \(name) to accept · \(age(now.timeIntervalSince(since)))"
    }
    /// True when a sent job is parked at the receiver's Accept prompt.
    static func isWaitingForAccept(_ j: SentJob) -> Bool { j.status == .needsYou && j.note == "Waiting for them to accept" }
    static func time(_ d: Date, tz: TimeZone = .current) -> String {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; f.timeZone = tz
        return f.string(from: d)
    }
    /// `needsYouAsSender`: the sender's list says "Needs you: <reason>"; the receiver's keeps "Needs them".
    static func label(_ s: PeerStatus, note: String = "", resumeAt: Date? = nil, peer: String = "", needsYouAsSender: Bool = false, tz: TimeZone = .current) -> String {
        switch s {
        case .paused:
            guard let at = resumeAt else { return "Paused" }
            return "Paused · resumes \(time(at, tz: tz))" + (peer.isEmpty ? "" : " (\(peer)'s time)")
        case .needsYou where needsYouAsSender:
            let r = note.trimmingCharacters(in: .whitespacesAndNewlines)
            return r.isEmpty ? "Needs you" : "Needs you: \(String(r.prefix(48)))"
        default: return s.pillLabel
        }
    }
}

/// Settings-list row: >= 44pt tall, full-row hover highlight, whole row hit area.
private struct HoverRowModifier: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Theme.Space.s2).frame(minHeight: Theme.Hit.row)
            .background(hovering ? Theme.Token.hoverFill : .clear, in: .rect(cornerRadius: Theme.Radius.sm))
            .contentShape(.rect(cornerRadius: Theme.Radius.sm))
            .onHover { hovering = $0 }
            .motion(.micro, value: hovering)
            .padding(.horizontal, -Theme.Space.s2)
    }
}

extension View {
    /// 44pt row with a hover highlight (Theme.Hit.row).
    func hoverRow() -> some View { modifier(HoverRowModifier()) }
}

/// Text-only button with a >= 32pt pill hit area and hover state.
struct QuietTextButton: View {
    let title: String
    var rest: Color = Theme.Token.text2
    var hover: Color = Theme.Token.text0
    var weight: Font.Weight = .regular
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).fontWeight(weight).padding(.horizontal, Theme.Space.s3)
                .frame(minWidth: Theme.Hit.control, minHeight: Theme.Hit.control).contentShape(Capsule())
        }
        .buttonStyle(PillButtonStyle(shape: Capsule(), rest: rest, hover: hover))
    }
}

/// One desk in the Peers sheet list; a second lane shows as its own row.
extension PeerEngine.DeskInfo { var rowId: String { "\(key)|\(lane)" } }

struct PeerDeskRow: View {
    let desk: PeerEngine.DeskInfo
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(desk.peer) · \(desk.project)\(desk.lane > 1 ? " · Lane \(desk.lane)" : "")").font(.callout.weight(.medium))
            Text((desk.running.map { "Running: \($0)" } ?? "Waiting to start") + (desk.inLine > 0 ? " · \(desk.inLine) in line" : ""))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
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

    private func deskLine(_ j: InboundJob) -> String? {
        guard let key = j.desk, !j.status.isFinal else { return nil }
        return PeerText.deskLine(peer: j.peerLabel, project: PeerNaming.deskProject(key), inLine: PeerService.engine.inLineCount(desk: key))
    }

    private func pill(_ s: PeerStatus, text: String? = nil) -> some View {
        Text(text ?? s.pillLabel).font(.callout.weight(s.isLoud ? .semibold : .regular))
            .foregroundStyle(s.isLoud ? Theme.text : Theme.hubSecondary).lineLimit(1)
    }

    private func sentRow(_ j: SentJob) -> some View {
        HubRowFrame {
            HStack(spacing: 12) {
                Image(systemName: "paperplane").frame(width: 32).foregroundStyle(Theme.hubSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text([j.missionName, j.title].compactMap { $0 }.joined(separator: " · ")).font(.body).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.tail)
                    Text("\(j.peerLabel) · \(peerElapsed(j.created, to: j.status.isFinal ? j.updated : nil))")
                        .font(.callout).foregroundStyle(Theme.hubSecondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                pill(j.status, text: PeerStatusText.isWaitingForAccept(j) ? PeerStatusText.waitingForAccept(name: j.peerLabel, since: j.created) : PeerStatusText.label(j.status, note: j.note, resumeAt: j.resumeAt, peer: j.peerLabel, needsYouAsSender: true))
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
                    Text([j.req.missionName, j.req.title].compactMap { $0 }.joined(separator: " · ")).font(.body).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.tail)
                    Text("\(j.peerLabel) · \(peerElapsed(j.received, to: j.finished))")
                        .font(.callout).foregroundStyle(Theme.hubSecondary).lineLimit(1)
                    if let d = deskLine(j) { Text(d).font(.callout).foregroundStyle(Theme.hubSecondary).lineLimit(1) }
                }
                Spacer(minLength: 4)
                if !j.flags.isEmpty {
                    Label("\(j.flags.count)", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(Theme.text).help(j.flags.joined(separator: "\n"))
                }
                if j.status == .queued && j.inboundMode == .ask {
                    QuietTextButton(title: "Decline", rest: Theme.hubSecondary, hover: Theme.text) { PeerService.engine.decline(j.id) }
                    QuietTextButton(title: "Accept", rest: Theme.text, hover: Theme.text, weight: .semibold) { PeerService.engine.accept(j.id) }
                } else {
                    pill(j.status, text: PeerStatusText.label(j.status, note: j.note, resumeAt: j.resumeAt, peer: "My"))
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
                .onAppear { PeerService.engine.watchJob(jobId: job.jobId) }
                .onDisappear { PeerService.engine.unwatchJob(jobId: job.jobId) }
            Text("\(live.peerLabel) · \(PeerStatusText.label(live.status, note: live.note, resumeAt: live.resumeAt, peer: live.peerLabel, needsYouAsSender: true))\(live.note.isEmpty || live.status == .needsYou ? "" : " · \(live.note)")")
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
                                    .foregroundStyle(it.kind == .nack ? Theme.Hue.peerFail : Color.primary).id(i)
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
        .controlSize(.large)
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
            if let key = job.desk, !job.status.isFinal {
                Text(PeerText.deskLine(peer: job.peerLabel, project: PeerNaming.deskProject(key), inLine: PeerService.engine.inLineCount(desk: key)))
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !job.flags.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Looks like it may be trying to steer Claude", systemImage: "exclamationmark.triangle").font(.callout.weight(.semibold))
                    ForEach(job.flags, id: \.self) { Text("• \($0)").font(.callout) }
                }
            }
            if let out = job.worktree, out.hasPrefix(PeerDirs.realHome(NSHomeDirectory()) + "/True/") {
                HStack {
                    Text("Output: ~" + out.dropFirst(PeerDirs.realHome(NSHomeDirectory()).count)).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open folder") { NSWorkspace.shared.open(URL(fileURLWithPath: out)) }
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
        .controlSize(.large)
    }
}

@MainActor
final class PeersWindow {
    static let shared = PeersWindow()
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    /// Run 39: advertises and browses only while the window is open.
    let lan = PeerLanCoordinator(transport: PeerLanNetwork(), engine: PeerService.engine)

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Peers"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: PeersView(lan: lan))
            w.center()
            window = w
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lan.close() }
            }
        }
        lan.onPrompt = { [weak self] p in
            guard let self, let w = self.window else { return }
            if !w.isKeyWindow { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
            guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
            let c = UNMutableNotificationContent()
            c.title = "\(p.name) wants to pair"
            c.body = "Open Peers to accept."
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "peer-lan-pair", content: c, trigger: nil))
        }
        lan.open()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// One peer: name, the health line in words, Revoke. 44 pt row, 32 pt control, full-row hover.
struct PeerHealthRow<Extra: View>: View {
    let label: String, line: String, revoke: () -> Void
    @ViewBuilder var extra: Extra
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                Text(line).font(.caption).foregroundStyle(.secondary)
                extra
            }
            Spacer()
            Button("Revoke", role: .destructive, action: revoke).frame(height: 32)
        }
        .frame(minHeight: 44)
        .hoverRow()
    }
}

struct PeersView: View {
    @ObservedObject var lan: PeerLanCoordinator
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
    @State private var deskOn = PeerSettings.desk
    @State private var desks: [PeerEngine.DeskInfo] = []
    @State private var askOn = PeerSettings.ask
    @State private var share = PeerSettings.share
    @State private var dirs = PeerSettings.allowedDirs
    @State private var dirNote: String?
    @State private var offers: [PeerOffer] = []
    @State private var shares: [(peer: String, mailbox: String, repo: SharedRepo)] = []
    @State private var removed: [PeerLinkRecord] = []
    @State private var held: [PeerEngine.HeldGroup] = []
    @State private var problems: [PeerProblem] = []
    @State private var healthLines: [String: String] = [:]
    @State private var resumeNote: String?

    var body: some View {
        ScrollView { content }
            .frame(width: 460, height: 640, alignment: .topLeading)
            .onAppear(perform: reload)
            .onReceive(NotificationCenter.default.publisher(for: .peersChanged)) { _ in reload() }
    }

    private func reload() {
        let e = PeerService.engine
        desks = e.desks()
        offers = e.pendingOffers().filter { $0.status != .accepted }; shares = e.shares()
        links = e.peerLinks(); connected = e.isConnected; wanted = e.wantsRelay; paired = e.lastPaired
        removed = e.removedByThem(); held = e.heldGroups(); problems = e.problems()
        healthLines = Dictionary(uniqueKeysWithValues: links.map { ($0.mailboxId, e.healthLine(for: $0)) })
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            if wanted {
                Text(PeerHealth.relayLine(connected: connected)).font(.callout).foregroundStyle(.secondary)
            }
            if let paired { Text("Paired with \(paired)").font(.callout.weight(.semibold)) }
            if !problems.isEmpty { problemsFeed }
            PeerLanSection(lan: lan)
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
                    QuietTextButton(title: "Remove", rest: .secondary, hover: .primary) { dirs.removeAll { $0 == d }; PeerSettings.allowedDirs = dirs }
                }
                .hoverRow()
            }
            HStack {
                Button("Add folder…", action: addDir)
                if let dirNote { Text(dirNote).font(.caption).foregroundStyle(.secondary) }
            }
            SharedProjectsSection(offers: offers, shares: shares)
            Toggle("One session per peer project", isOn: Binding(get: { deskOn }, set: { deskOn = $0; PeerSettings.desk = $0 }))
            Text("Jobs from the same friend on the same project share one Claude session, one after another.").font(.caption).foregroundStyle(.secondary)
            ForEach(desks, id: \.rowId) { d in PeerDeskRow(desk: d).hoverRow() }
            Toggle("Let peers send follow-ups", isOn: Binding(get: { steering }, set: { steering = $0; PeerSettings.steering = $0 }))
            Toggle("Let peers chat with my agents", isOn: Binding(get: { chatOn }, set: { chatOn = $0; PeerSettings.chat = $0 }))
            Toggle("Answer peers' questions from my brain", isOn: Binding(get: { askOn }, set: { askOn = $0; PeerSettings.ask = $0 }))
            Picker("Share with the sender", selection: Binding(get: { share }, set: { share = $0; PeerSettings.share = $0 })) {
                Text("Status only").tag(PeerShare.status)
                Text("Activity").tag(PeerShare.activity)
                Text("Everything").tag(PeerShare.everything)
            }
            .pickerStyle(.segmented)
            if share == .everything {
                Text("Shows commands and the agent's words. Secrets are masked, not guaranteed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
                PeerHealthRow(label: l.label, line: l.confirmed ? (healthLines[l.mailboxId] ?? "") : "Waiting for them to accept",
                              revoke: { PeerService.engine.revoke(mailboxId: l.mailboxId) }) { AskProjectsField(mailboxId: l.mailboxId) }
            }
            ForEach(removed) { rec in
                HStack {
                    Text("Link with \(rec.label) removed by them at \(PeerStatusText.time(rec.at))").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("New invite") {
                        let code = PeerService.engine.invite(); inviteText = code; copied = true
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string); reload()
                    }.frame(height: 32)
                }
                .frame(minHeight: 44)
                .hoverRow()
            }
            ForEach(held, id: \.mailboxId) { g in
                HStack {
                    Text("\(g.count) held job\(g.count == 1 ? "" : "s") for \(g.label)").font(.callout)
                    Spacer()
                    Button("Resume") {
                        switch PeerService.engine.resumeHeld(mailboxId: g.mailboxId) {
                        case .success(let ids): resumeNote = "Sent \(ids.count) again to \(g.label)"
                        case .failure(.invalid(let m)): resumeNote = m
                        }
                        reload()
                    }.disabled(!g.canResume).frame(height: 32)
                }
                .frame(minHeight: 44)
                .hoverRow()
            }
            if let resumeNote { Text(resumeNote).font(.caption).foregroundStyle(.secondary) }
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
        .controlSize(.large)
        .accessibilityIdentifier("scr.group.peers")
    }

    private var problemsFeed: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Peer problems").font(.headline)
                Spacer()
                Button("Clear") { PeerService.engine.clearProblems(); reload() }.frame(height: 32)
            }
            ForEach(problems.prefix(8)) { p in
                Text("\(PeerStatusText.time(p.at)) · \(p.text)").font(.callout).foregroundStyle(.secondary)
                    .frame(minHeight: 44, alignment: .leading).hoverRow()
            }
        }
        .accessibilityIdentifier("scr.group.peers.problems")
    }

    private func addDir() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false; p.prompt = "Allow"
        guard p.runModal() == .OK, let url = p.url else { return }
        let path = url.resolvingSymlinksInPath().path
        guard PeerDirs.canAllow(path) else { dirNote = "That folder is too broad to allow."; return }
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

/// Run 33: which brain projects one peer may ask about (`peer.ask.projects`). Comma-separated slugs; empty = they can't ask.
/// Run 39: "On this network" — other Macs running True on the same Wi-Fi.
struct PeerLanSection: View {
    @ObservedObject var lan: PeerLanCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("On this network").font(.headline)
            switch lan.lanState {
            case .denied:
                Text("True can't see this network. Allow it in System Settings → Privacy & Security → Local Network")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Open Local Network settings") {
                    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") { NSWorkspace.shared.open(u) }
                }
            case .cantSearch:
                Text("Can't search this network right now. Use an invite code below.").font(.callout).foregroundStyle(.secondary)
            case .ok:
                if lan.rows.isEmpty {
                    Text("No Macs with True here. Open Peers on the other Mac, on the same Wi-Fi. Or use an invite code below.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let p = lan.prompt {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(p.name) wants to pair. Check it shows:").font(.callout)
                    Text(p.code).font(Theme.Fonts.codeLarge).textSelection(.enabled)
                    HStack {
                        Button("Accept") { lan.accept() }.keyboardShortcut(.defaultAction)
                        Button("Decline") { lan.cancelSession() }
                    }
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            ForEach(lan.rows) { r in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(r.name)
                        Spacer()
                        trailing(r)
                    }
                    if case .check(let code)? = lan.sendState[r.id] {
                        Text("Check \(r.name) shows:").font(.callout).foregroundStyle(.secondary)
                        Text(code).font(Theme.Fonts.codeLarge).textSelection(.enabled)
                    }
                }
                .hoverRow()
            }
            Divider()
        }
    }

    private func note(_ s: String) -> some View { Text(s).font(.callout).foregroundStyle(.secondary) }

    /// invite() is a no-op while any pairing is open (a request in, or a check out), so say so instead of a dead button.
    private var inviteLocked: Bool { lan.prompt != nil || lan.sendState.values.contains { $0.busy } }
    private func inviteButton(_ r: PeerLanCoordinator.Row, _ title: String = "Invite") -> some View {
        Button(title) { lan.invite(rowId: r.id) }.disabled(inviteLocked)
    }

    @ViewBuilder private func trailing(_ r: PeerLanCoordinator.Row) -> some View {
        switch lan.sendState[r.id] {
        case nil:
            if r.paired { note("Paired") } else { inviteButton(r) }
        case .connecting?: note("Connecting…")
        case .cantReach?: HStack { note("Can't reach this Mac"); inviteButton(r, "Invite again") }
        case .check?: HStack { Button("Pair") { lan.confirmSend() }.keyboardShortcut(.defaultAction); Button("Cancel") { lan.cancelSession() } }
        case .waitingAccept?: note("Waiting for \(r.name) to accept…")
        case .pairing?: note("Pairing…")
        case .paired?: note("Paired")
        case .declined?: HStack { note("\(r.name) declined"); inviteButton(r) }
        case .busy?: HStack { note("Busy. Try again in a moment"); inviteButton(r) }
        case .timedOut?: HStack { note("Timed out"); inviteButton(r) }
        case .failed?: HStack { note("Couldn't pair. Try again."); inviteButton(r) }
        case .relayTimeout?: note("Couldn't reach the relay. Check the internet and try again.")
        }
    }
}

struct AskProjectsField: View {
    let mailboxId: String
    @State private var text: String

    init(mailboxId: String) {
        self.mailboxId = mailboxId
        _text = State(initialValue: (PeerSettings.askProjects[mailboxId] ?? []).joined(separator: ", "))
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("Can ask my brain about:").font(.caption).foregroundStyle(.secondary)
            TextField("project names, comma-separated", text: $text).textFieldStyle(.roundedBorder).font(.caption).onSubmit(save)
        }
        .onChange(of: text) { _, _ in save() }
    }

    private func save() {
        var all = PeerSettings.askProjects
        let slugs = PeerSettings.parseSlugs(text)
        all[mailboxId] = slugs.isEmpty ? nil : slugs
        PeerSettings.askProjects = all
    }
}


/// Run 34: pending offers (Accept / Decline) and the accepted shares (Remove). URLs are plain text, never links.
struct SharedProjectsSection: View {
    let offers: [PeerOffer]
    let shares: [(peer: String, mailbox: String, repo: SharedRepo)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shared projects").font(.headline)
            ForEach(offers) { o in card(o) }
            if shares.isEmpty && offers.isEmpty {
                Text("None. A peer can offer you a repo; every job on it waits for your OK.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(shares, id: \.repo.slug) { s in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(s.repo.slug) · \(s.peer)")
                        Text(s.repo.url).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    QuietTextButton(title: "Remove", rest: .secondary, hover: .primary) { PeerService.engine.removeShare(mailbox: s.mailbox, slug: s.repo.slug) }
                }
                .hoverRow()
            }
        }
    }

    @ViewBuilder private func card(_ o: PeerOffer) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(o.incoming ? "\(o.peerLabel) offers \(o.name)" : "You offered \(o.name) to \(o.peerLabel)").font(.callout.weight(.semibold))
            Text(o.url).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(2)
            if !o.note.isEmpty { Text(o.note).font(.caption) }
            switch (o.incoming, o.status) {
            case (true, .pending), (true, .failed):
                if o.status == .failed { Text(o.reason).font(.caption).foregroundStyle(Theme.Hue.peerFail) }
                HStack {
                    Button(o.status == .failed ? "Try again" : "Accept") { PeerService.engine.acceptOffer(o.id) }
                    Button("Decline") { PeerService.engine.declineOffer(o.id) }
                }
            case (true, .cloning): Text("Copying it to this Mac…").font(.caption).foregroundStyle(.secondary)
            case (_, .declined):
                Text(o.reason.isEmpty ? "Declined" : "Declined: \(o.reason)").font(.caption).foregroundStyle(.secondary)
                QuietTextButton(title: "Dismiss", rest: .secondary, hover: .primary) { PeerService.engine.dismissOffer(o.id) }
            case (false, _): Text("Waiting for them").font(.caption).foregroundStyle(.secondary)
            default: EmptyView()
            }
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}
