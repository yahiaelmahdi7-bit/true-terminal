import SwiftUI
import AppKit

/// ⇧⌘R: the final answer of each recent turn in the focused pane's Claude session.
struct ResultsSheet: View {
    let store: ResultsStore
    @State private var expanded: Set<Int> = [0]
    @State private var copied: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Results").font(.headline)
                if !store.folder.isEmpty { Text(store.folder).font(.subheadline).foregroundStyle(.secondary) }
                Spacer()
                Button("Done") { store.close() }.keyboardShortcut(.cancelAction)
            }
            Divider()
            content
        }
        .padding(16)
        .frame(minWidth: 480, idealWidth: 640, minHeight: 400, idealHeight: 560)
        .onChange(of: store.isOpen) { _, open in if open { expanded = [0]; copied = nil } }
    }

    @ViewBuilder private var content: some View {
        switch store.phase {
        case .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .noSession:
            ContentUnavailableView("No Claude session in this pane", systemImage: "terminal")
        case .notFound:
            ContentUnavailableView("Transcript not found", systemImage: "doc.questionmark")
        case .empty:
            ContentUnavailableView("No results yet", systemImage: "text.bubble")
        case .loaded(let results):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(results) { r in row(r) }
                }
            }
        }
    }

    private func row(_ r: TurnResult) -> some View {
        let open = expanded.contains(r.id)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                if open { expanded.remove(r.id) } else { expanded.insert(r.id) }
            } label: { header(r, open: open) }
            .buttonStyle(.plain)
            if open { expandedBody(r) }
        }
        .padding(10)
        .background(Theme.hubCardFill, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hubCardStroke))
    }

    private func header(_ r: TurnResult, open: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: open ? "chevron.down" : "chevron.right")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary).frame(width: 10)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(Self.when(r.date)).font(.caption.weight(.medium)).help(Self.absolute(r.date))
                    if !r.prompt.isEmpty { Text(r.prompt).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                if !open {
                    Text(Self.firstLine(r.markdown)).font(.callout).lineLimit(1).foregroundStyle(.primary)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
    }

    private func expandedBody(_ r: TurnResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            MarkdownView(source: r.markdown)
            HStack(spacing: 8) {
                Button(copied == r.id ? "Copied" : "Copy") { copy(r) }
                Button("Show in Terminal") { store.showInTerminal(r) }
            }
            if store.notInScrollback == r.id {
                Text("Not in this pane's scrollback anymore").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func copy(_ r: TurnResult) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(r.markdown, forType: .string)
        copied = r.id
        // One-shot feedback reset; nothing repeats.
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if copied == r.id { copied = nil }
        }
    }

    static func when(_ d: Date?) -> String {
        guard let d else { return "Earlier" }
        return RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date())
    }
    static func absolute(_ d: Date?) -> String {
        d.map { $0.formatted(date: .abbreviated, time: .standard) } ?? ""
    }
    static func firstLine(_ md: String) -> String {
        md.split(whereSeparator: \.isNewline).map { ResultsProbe.strip(String($0)) }.first { !$0.isEmpty } ?? ""
    }
}

/// Renders `MarkdownBlock`s: headings, fenced code, verbatim tables, lists, paragraphs.
struct MarkdownView: View {
    let source: String

    var body: some View {
        let blocks = MarkdownBlock.parse(source)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in block(b) }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func block(_ b: MarkdownBlock) -> some View {
        switch b {
        case .heading(let level, let text):
            inline(text).font(Self.headingFont(level)).padding(.top, 4)
        case .code(let code):
            mono(code)
        case .table(let rows):
            mono(rows.joined(separator: "\n"))
        case .list(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, i in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(i.marker).foregroundStyle(.secondary)
                        inline(i.text)
                    }
                    .padding(.leading, CGFloat(i.indent) * 6)
                }
            }
        case .paragraph(let text):
            inline(text)
        }
    }

    private func mono(_ s: String) -> some View {
        ScrollView(.horizontal) {
            Text(s).font(.system(.callout, design: .monospaced)).fixedSize().padding(8)
        }
        .background(Theme.hubCardFill, in: .rect(cornerRadius: 6))
    }

    private func inline(_ s: String) -> Text {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let a = try? AttributedString(markdown: s, options: opts) { return Text(a) }
        return Text(s)
    }

    static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title3.weight(.semibold)
        case 2: return .headline.weight(.semibold)
        default: return .subheadline.weight(.semibold)
        }
    }
}
