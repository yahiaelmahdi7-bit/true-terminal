import AppKit
import SwiftUI

extension CloudJob {
    /// Plain words for the status chip, same voice as the rest of the Hub.
    var chipLabel: String {
        switch status {
        case "working": return foremanStatus == "QUEUED" ? "Queued" : "Working"
        case "needsYou": return "Needs you"
        case "done": return "Done"
        default: return "Failed"
        }
    }
    var chipLoud: Bool { isWorking || needsYou || isFailed }
}

/// "Sonnet 5.5 · High": what the job was started with.
struct ModelChip: View {
    let text: String
    var body: some View {
        Text(text).font(.caption).foregroundStyle(Theme.hubSecondary).lineLimit(1).fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 2).background(Color.white.opacity(0.07), in: .capsule)
    }
}

struct CloudStatusChip: View {
    let job: CloudJob
    var body: some View {
        Text(job.chipLabel).font(.callout.weight(job.chipLoud ? .semibold : .regular))
            .foregroundStyle(job.chipLoud ? Theme.text : Theme.hubSecondary).lineLimit(1)
    }
}

/// One job: timeline, the question when it needs you, and the result diff with Land.
struct CloudJobSheet: View {
    let job: CloudJob
    var done: () -> Void
    @State private var detail: CloudJobDetail?
    @State private var events: [CloudEvent] = []
    @State private var answer = ""
    @State private var diff: String?
    @State private var note: String?
    @State private var busy = false
    @State private var landRepo = ""
    @State private var landed: CloudLand.Result?

    private var live: CloudJob { CloudStore.shared.jobs.first { $0.id == job.id } ?? detail?.job ?? job }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cloud job · \(live.repo)").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(live.title).font(.headline).lineLimit(1).truncationMode(.tail); CloudStatusChip(job: live)
                        if let chip = live.modelChip { ModelChip(text: chip) }
                    }
                }
                Spacer()
                if live.isWorking { Button("Stop") { act { _ = try await CloudStore.shared.client.stop(job.id) } } }
                Button("Done") { done() }.keyboardShortcut(.defaultAction)
            }
            if live.needsYou { needsYouBox }
            if live.isFailed, let r = live.reason { Text(r).font(.callout).foregroundStyle(.secondary).lineLimit(3) }
            Text("Timeline").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(events) { e in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(e.type).foregroundStyle(.secondary).frame(width: 110, alignment: .leading).lineLimit(1)
                            Text(e.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }.font(.system(.caption, design: .monospaced))
                    }
                    if events.isEmpty { Text("No events yet.").font(.caption).foregroundStyle(.secondary) }
                }
            }.frame(minHeight: 120)
            if live.isDone || live.needsYou || live.isFailed { resultBox }
            if let note { Text(note).font(.callout).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled) }
        }
        .padding(16).frame(width: 640, height: 560)
        .task {
            detail = try? await CloudStore.shared.client.detail(job.id)
            while !Task.isCancelled {
                await reloadEvents()
                if CloudStore.shared.jobs.first(where: { $0.id == job.id })?.isWorking != true && !events.isEmpty { break }
                try? await Task.sleep(for: .seconds(3))
            }
            try? await CloudStore.shared.client.markViewed(job.id)
        }
    }

    private var needsYouBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(live.needsYouReason ?? "The job needs an answer to continue.").font(.callout).textSelection(.enabled)
            HStack {
                TextField("Your answer", text: $answer).textFieldStyle(.roundedBorder).onSubmit(sendAnswer)
                Button("Answer", action: sendAnswer).disabled(busy || answer.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(10).background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }

    private var resultBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Result").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button(diff == nil ? "Show diff" : "Reload diff") { act { diff = try await CloudStore.shared.client.diff(job.id) } }
            }
            if let diff {
                ScrollView([.vertical, .horizontal]) {
                    Text(diff.isEmpty ? "No changes." : diff).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 100, maxHeight: 180)
                if !diff.isEmpty { landRow }
            }
        }
    }

    private var landRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let landed {
                Text("Landed on branch \(landed.branch) in \(landed.path). main is untouched; nothing was pushed.")
                    .font(.callout).textSelection(.enabled)
            } else {
                HStack {
                    TextField("Local repo folder", text: $landRepo).textFieldStyle(.roundedBorder)
                    Button("Land") { land() }.disabled(busy || landRepo.isEmpty)
                }
                Text("Creates a new branch in a sibling folder and commits the diff there. Never touches main, never pushes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func sendAnswer() {
        let text = answer
        act { _ = try await CloudStore.shared.client.answer(job.id, text: text); answer = ""; await CloudStore.shared.refresh() }
    }

    private func land() {
        let (repo, d, base, title) = (landRepo, diff ?? "", detail?.baseSha, live.title)
        busy = true
        Task {
            let r: Result<CloudLand.Result, Error> = await Task.detached {
                Result { try CloudLand().land(localRepo: repo, jobID: job.id, title: title, baseSha: base, diff: d) }
            }.value
            switch r {
            case .success(let l): landed = l; note = nil
            case .failure(let e): note = e.localizedDescription
            }
            busy = false
        }
    }

    private func reloadEvents() async {
        if let e = try? await CloudStore.shared.client.events(job.id) { events = e }
    }

    private func act(_ work: @escaping () async throws -> Void) {
        busy = true; note = nil
        Task {
            do { try await work() } catch { note = error.localizedDescription }
            busy = false
        }
    }
}
