import SwiftUI
import AppKit

/// Agents ▸ Context Cleaner…: list on the left, BEFORE | AFTER review on the right, action bar below.
struct CleanerSheet: View {
    @Bindable var cleaner: ContextCleaner

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            HStack(spacing: 0) {
                list.frame(width: 340)
                Divider().opacity(0.5)
                detail
            }
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 920, height: 640)
        .onAppear { cleaner.open() }
        .onDisappear { cleaner.close() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "wand.and.sparkles").font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Context Cleaner").font(.headline)
                let t = cleaner.totals
                Text("Selected: \(t.files) files · \(t.before.formatted()) → \(t.after.formatted()) tok")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Picker("Model", selection: $cleaner.model) {
                ForEach([AgentModel.opus, .sonnet, .fable], id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).frame(width: 210).labelsHidden()
            .disabled(cleaner.running)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .glassSurface(Rectangle(), hairline: false)
    }

    // MARK: List

    private var groups: [(project: String, rows: [CleanerRow])] {
        var order: [String] = []
        var by: [String: [CleanerRow]] = [:]
        for r in cleaner.rows {
            if by[r.file.project] == nil { order.append(r.file.project) }
            by[r.file.project, default: []].append(r)
        }
        return order.map { ($0, by[$0] ?? []) }
    }

    private var list: some View {
        Group {
            if cleaner.scanning {
                Text("Scanning…").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if cleaner.rows.isEmpty {
                Text("No context files found").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                        ForEach(groups, id: \.project) { g in
                            Text(g.project).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 3)
                            ForEach(g.rows) { r in row(r) }
                        }
                    }.padding(.bottom, 8)
                }
            }
        }
    }

    private func row(_ r: CleanerRow) -> some View {
        let i = cleaner.rows.firstIndex(where: { $0.id == r.id })
        let locked = r.file.lock != nil
        return HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { r.rewriteChecked },
                                     set: { v in if let i { cleaner.rows[i].rewriteChecked = v } }))
                .labelsHidden().toggleStyle(.checkbox).disabled(locked || cleaner.running)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(r.file.kind.rawValue).font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.white.opacity(0.14), in: .capsule)
                    Text(fileName(r.file)).font(.callout).lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: 6) {
                    Text("\(r.file.tokens.formatted()) tok · \(age(r.file.mtime))")
                    if r.file.kind == .global { Text("· Loaded into every session") }
                    if let l = r.file.lock { Text("· \(l.reason)").foregroundStyle(.orange) }
                }
                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                statusLine(r)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .opacity(locked ? 0.55 : 1)
        .background(cleaner.selectedID == r.id ? Color.white.opacity(0.12) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { cleaner.selectedID = r.id }
    }

    @ViewBuilder private func statusLine(_ r: CleanerRow) -> some View {
        switch r.status {
        case .idle: EmptyView()
        case .queued: Text("Queued").font(.caption2).foregroundStyle(.secondary)
        case .rewriting:
            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Rewriting…") }
                .font(.caption2).foregroundStyle(.secondary)
        case .error(let m): Text("Error: \(m)").font(.caption2).foregroundStyle(.red).lineLimit(2)
        case .done(let o):
            if o.isLean { Text("Lean").font(.caption2).foregroundStyle(.secondary) }
            else {
                let after = o.output.utf8.count / 4
                let pct = r.file.tokens > 0 ? Int((Double(after - r.file.tokens) / Double(r.file.tokens) * 100).rounded()) : 0
                Text("\(r.file.tokens.formatted()) → \(after.formatted()) tok (\(pct)%)")
                    .font(.caption2).foregroundStyle(.green).monospacedDigit()
            }
        }
        if let a = r.applyResult { Text(a).font(.caption2).foregroundStyle(a == "Applied" ? .green : .red) }
    }

    private func fileName(_ f: ContextFile) -> String {
        let p = ProjectList.abbreviate(f.path)
        let parts = p.split(separator: "/")
        return parts.suffix(2).joined(separator: "/")
    }

    private func age(_ d: Date) -> String {
        let s = Date().timeIntervalSince(d)
        if s < 3600 { return "\(max(1, Int(s / 60)))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86400))d"
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let r = cleaner.rows.first(where: { $0.id == cleaner.selectedID }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(ProjectList.abbreviate(r.file.path)).font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if let o = r.outcome, !o.isLean, let i = cleaner.rows.firstIndex(where: { $0.id == r.id }) {
                        Toggle("Apply", isOn: Binding(get: { cleaner.rows[i].applyChecked },
                                                      set: { cleaner.rows[i].applyChecked = $0 }))
                            .toggleStyle(.checkbox)
                    }
                }
                if let o = r.outcome {
                    Text(o.isLean ? "Already lean — nothing to apply."
                         : "\(r.file.tokens.formatted()) → \((r.tokensAfter ?? 0).formatted()) tok")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    if !o.dropped.isEmpty { chips(o.dropped) }
                    factCheckView(o.factCheck)
                }
                if case .error(let m) = r.status { Text(m).font(.callout).foregroundStyle(.red) }
                HStack(spacing: 8) {
                    pane("BEFORE", r.file.content)
                    pane("AFTER", r.outcome?.output ?? "")
                }
            }
            .padding(12)
        } else {
            Text("Select a file").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func pane(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            ReadOnlyText(text: text)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.hairline))
        }
    }

    private func chips(_ facts: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Not in the rewrite (\(facts.count)) — stale ones may be fine to drop")
                .font(.caption2).foregroundStyle(.yellow)
            ScrollView {
                FlowLayout(spacing: 4) {
                    ForEach(facts, id: \.self) { f in
                        Text(f).font(.system(size: 10, design: .monospaced)).lineLimit(1)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.yellow.opacity(0.18), in: .capsule)
                            .foregroundStyle(.yellow)
                    }
                }
            }.frame(maxHeight: 64)
        }
    }

    @ViewBuilder private func factCheckView(_ fc: FactCheck) -> some View {
        switch fc {
        case .flagged(let lost):
            VStack(alignment: .leading, spacing: 3) {
                Text("Possible lost fact (\(lost.count)) — Jev found no trace of these in the rewrite")
                    .font(.caption2).foregroundStyle(.orange)
                ScrollView {
                    FlowLayout(spacing: 4) {
                        ForEach(lost, id: \.text) { l in
                            Text(l.chip).font(.system(size: 10)).lineLimit(1)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.orange.opacity(0.18), in: .capsule)
                                .foregroundStyle(.orange)
                                .help(l.text)
                        }
                    }
                }.frame(maxHeight: 64)
            }
        case .off:
            Text("fact check off").font(.caption2).foregroundStyle(.secondary)
        case .largeRewrite:
            Text("large rewrite — review by eye").font(.caption2).foregroundStyle(.secondary)
        case .notRun, .clean:
            EmptyView()
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if let b = cleaner.banner {
                Text(b).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button("Undo Last Apply") { cleaner.undoLast() }.disabled(cleaner.running)
            Button("Rewrite Selected (\(cleaner.toRewrite.count))") { cleaner.rewriteSelected() }
                .disabled(cleaner.running || cleaner.toRewrite.isEmpty)
            Button("Apply \(cleaner.appliable.count) Changes") { cleaner.applySelected() }
                .buttonStyle(.borderedProminent)
                .disabled(cleaner.running || cleaner.appliable.isEmpty)
            Button("Close") { cleaner.close() }.keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .glassSurface(Rectangle(), hairline: false)
    }
}

/// Read-only, selectable, monospaced, scrollable text.
struct ReadOnlyText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false; tv.isSelectable = true
            tv.drawsBackground = false
            tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            tv.textColor = NSColor(white: 0.88, alpha: 1)
            tv.textContainerInset = NSSize(width: 6, height: 6)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView, tv.string != text else { return }
        tv.string = text
    }
}

/// Wrapping row layout for the dropped-fact chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? 400, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let a = arrange(bounds.width, subviews)
        for (i, p) in a.points.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        var pts: [CGPoint] = []
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            pts.append(CGPoint(x: x, y: y))
            x += sz.width + spacing; rowH = max(rowH, sz.height); maxX = max(maxX, x)
        }
        return (pts, CGSize(width: maxX, height: y + rowH))
    }
}
