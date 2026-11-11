import SwiftUI

/// The Usage history screen's content. Pure: data and choices come in, actions go out, so stills can draw it.
/// True black, mono type, greys only: Claude is the lighter bar, Codex the darker, and both carry a text label.
struct UsageHistoryView: View {
    let history: UsageHistory
    var segment: UsageSegment = .tokens
    var loading = false
    var now = Date()
    var calendar = Calendar.current
    var onSegment: (UsageSegment) -> Void = { _ in }
    var onPeriod: (UsagePeriod) -> Void = { _ in }
    var onDone: () -> Void = {}

    static let claudeShade = Theme.Token.text0, codexShade = Theme.Token.text3
    private let chartHeight: CGFloat = 88

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 16) {
                chips(UsageSegment.allCases.map { ($0.rawValue, $0 == segment, { onSegment($0) }) }, size: 12.5, mapped: UsageSegment.allCases)
                chips(UsagePeriod.allCases.map { ($0.label, $0 == history.period, { onPeriod($0) }) }, size: 11.5, mapped: UsagePeriod.allCases)
                notes
                if segment == .limits { limits } else if history.isEmpty && !loading { empty } else { summary; chart; table }
            }
            .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 24)
        }
        .frame(width: 520, alignment: .topLeading)
        .background(Theme.Token.bg0)
    }

    private var header: some View {
        HStack {
            Text(UsageHistoryCopy.title).font(.system(size: 14, weight: .medium, design: .monospaced)).foregroundStyle(Theme.Token.text0)
            Spacer()
            Button(action: onDone) {
                Text(UsageHistoryCopy.done).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Theme.Token.text0)
                    .padding(.horizontal, 10).frame(height: 24).background(Theme.Token.line, in: Capsule())
            }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 16)
    }

    /// A row of text chips; the chosen one sits on a hairline capsule. No colour.
    private func chips<T>(_ items: [(String, Bool, (T) -> Void)], size: CGFloat, mapped: [T]) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                Button { item.2(mapped[i]) } label: {
                    Text(item.0).font(.system(size: size, weight: item.1 ? .medium : .regular, design: .monospaced))
                        .foregroundStyle(item.1 ? Theme.Token.text0 : Theme.Token.text2)
                        .padding(.horizontal, 10).frame(height: 24)
                        .background(item.1 ? Theme.Token.line : Color.clear, in: Capsule())
                }.buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: error lines

    @ViewBuilder private var notes: some View {
        let lines = history.unreadable.map(UsageHistoryCopy.unreadable) + (history.skippedLines > 0 ? [UsageHistoryCopy.skipped(history.skippedLines)] : [])
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(lines, id: \.self) { Text($0).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.Token.text1) }
            }
        }
    }

    private var empty: some View {
        Text(UsageHistoryCopy.empty).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.Token.text2)
            .frame(maxWidth: .infinity, minHeight: 160)
    }

    // MARK: tokens and cost

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if segment == .cost {
                    Text(history.money(history.totalDollars)).font(.system(size: 26, weight: .medium, design: .monospaced))
                    Text(UsageHistoryCopy.est).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.Token.text2)
                } else {
                    Text(UsageHistoryCopy.tokens(history.totalTokens)).font(.system(size: 26, weight: .medium, design: .monospaced))
                    Text("tokens").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.Token.text2)
                }
            }.foregroundStyle(Theme.Token.text0)
            if !history.unpriced.isEmpty {
                Text(UsageHistoryCopy.unpricedNote(history.unpriced)).font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.Token.text2).lineLimit(2)
            }
        }
    }

    private func value(_ d: UsageHistory.Day) -> (claude: Double, codex: Double) {
        segment == .cost ? (d.claudeDollars, d.codexDollars) : (Double(d.claudeTokens), Double(d.codexTokens))
    }

    private var chart: some View {
        let peak = max(1, history.days.map { value($0).claude + value($0).codex }.max() ?? 1)
        let many = history.days.count > 30
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: many ? 1 : 3) {
                ForEach(history.days) { d in
                    let v = value(d)
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle().fill(Self.codexShade).frame(height: chartHeight * CGFloat(v.codex / peak))
                        Rectangle().fill(Self.claudeShade).frame(height: chartHeight * CGFloat(v.claude / peak))
                    }
                    .frame(maxWidth: 28).frame(height: chartHeight)
                    .clipShape(RoundedRectangle(cornerRadius: many ? 0.5 : 2, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity, alignment: history.days.count == 1 ? .leading : .center)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.Token.line).frame(height: 1) }
            HStack {
                Text(dayLabel(history.days.first?.day)); Spacer()
                if history.days.count > 1 { Text(dayLabel(history.days.last?.day)) }
            }.font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.Token.text2)
            HStack(spacing: 14) {
                if history.days.contains(where: { $0.claudeTokens > 0 }) { legend("Claude", Self.claudeShade) }
                if history.days.contains(where: { $0.codexTokens > 0 }) { legend("Codex", Self.codexShade) }
            }.font(.system(size: 11, design: .monospaced))
        }
    }

    private func legend(_ t: String, _ c: Color) -> some View {
        HStack(spacing: 5) { Rectangle().fill(c).frame(width: 8, height: 8).clipShape(RoundedRectangle(cornerRadius: 2))
            Text(t).foregroundStyle(Theme.Token.text1) }
    }

    private func dayLabel(_ key: String?) -> String {
        guard let key else { return "" }
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, p[1] >= 1, p[1] <= 12 else { return key }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(months[p[1] - 1]) \(p[2])"
    }

    private var table: some View {
        let rows = history.models(for: segment)
        return VStack(spacing: 0) {
            HStack {
                Text("Model"); Spacer()
                Text("Tokens").frame(width: 80, alignment: .trailing)
                Text("Est. cost").frame(width: 90, alignment: .trailing)
            }.font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Theme.Token.text2).padding(.bottom, 6)
            ForEach(rows) { m in
                HStack(spacing: 8) {
                    Text(m.name).foregroundStyle(Theme.Token.text0).lineLimit(1).truncationMode(.tail)
                    Text(AgentsCopy.provider(m.provider)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.Token.text2)
                    Spacer(minLength: 0)
                    Text(UsageHistoryCopy.tokens(m.tokens)).foregroundStyle(segment == .tokens ? Theme.Token.text0 : Theme.Token.text1)
                        .frame(width: 80, alignment: .trailing)
                    Text(m.dollars.map(history.money) ?? UsageHistoryCopy.unpricedTag)
                        .foregroundStyle(m.unpriced ? Theme.Token.text2 : (segment == .cost ? Theme.Token.text0 : Theme.Token.text1))
                        .frame(width: 90, alignment: .trailing)
                }.font(.system(size: 12.5, design: .monospaced)).padding(.vertical, 5)
            }
            Rectangle().fill(Theme.Token.line).frame(height: 1).padding(.top, 4)
            HStack {
                Text("Total").foregroundStyle(Theme.Token.text0); Spacer()
                Text(UsageHistoryCopy.tokens(history.totalTokens)).frame(width: 80, alignment: .trailing)
                Text(history.money(history.totalDollars)).frame(width: 90, alignment: .trailing)
            }.font(.system(size: 12.5, weight: .medium, design: .monospaced)).foregroundStyle(Theme.Token.text0).padding(.top, 8)
            if segment == .tokens {
                Text(UsageHistoryCopy.est).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.Token.text2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }
        }
    }

    // MARK: limits

    private var limits: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(UsageProvider.allCases, id: \.self) { p in
                let ws = history.windows.filter { $0.provider == p && $0.state != .none }
                let resets = history.resets.first { $0.provider == p }?.times ?? []
                VStack(alignment: .leading, spacing: 6) {
                    Text(AgentsCopy.provider(p)).font(.system(size: 12.5, weight: .medium, design: .monospaced)).foregroundStyle(Theme.Token.text0)
                    if ws.isEmpty { line("No reading", nil) }
                    ForEach(ws, id: \.kind) { w in
                        line(w.kind == .fiveHour ? AgentsCopy.fiveHour : AgentsCopy.week,
                             (w.usedPercent.map { "\(Int($0.rounded()))%" } ?? "–") + (UsageText.resetShort(w).map { "  " + $0 } ?? ""))
                    }
                    line("Resets seen", UsageHistoryCopy.resetsSeen(resets, period: history.period, calendar: calendar))
                }
            }
        }
    }

    private func line(_ k: String, _ v: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(k).foregroundStyle(Theme.Token.text2).frame(width: 90, alignment: .leading)
            if let v { Text(v).foregroundStyle(Theme.Token.text1).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 0)
        }.font(.system(size: 12, design: .monospaced))
    }
}
