import CoreGraphics
import Foundation
import Testing
@testable import True

@Suite struct AgentsPanelTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    func row(_ n: String, kind: ActivityRow.Kind = .seat, needs: Bool = false) -> ActivityRow {
        ActivityRow(kind: kind, id: n, name: n, status: "working", activity: "Working", project: "", provider: "Claude",
                    model: "", effort: nil, browser: nil, needsYou: needs, since: Self.now)
    }
    func win(_ p: UsageProvider, _ state: UsageFreshness, _ pct: Double? = 20) -> [UsageWindow] {
        [UsageKind.fiveHour, .weekly].map {
            UsageWindow(provider: p, kind: $0, usedPercent: state == .none ? nil : pct, resetsAt: Self.now, windowMins: 300,
                        readAt: state == .none ? nil : Self.now, state: state)
        }
    }

    @Test func collapsedShowsThreeRowsAndADisclosure() {
        let rows = (1...9).map { row("S\($0)") }
        let v = AgentsTile.visible(rows, expanded: false)
        #expect(v.rows.count == 3 && v.hasDisclosure)
        #expect(AgentsTile.visible(rows, expanded: true).rows.count == 9)
        #expect(AgentsCopy.all(9) == "All 9")
        let few = AgentsTile.visible((1...3).map { row("S\($0)") }, expanded: false)
        #expect(few.rows.count == 3 && !few.hasDisclosure)
    }

    @Test func needsYouComesFirstEvenWhenFifthOfFive() {
        let rows = [row("A"), row("B"), row("C"), row("D"), row("E", needs: true)]
        #expect(AgentsTile.visible(rows, expanded: false).rows.first?.name == "E")
    }

    @Test func buildersStayUnderBackground() {
        let drawn = AgentsTile.visible([row("B1", kind: .builder), row("S1"), row("S2")], expanded: false).rows
        #expect(drawn.map(\.name) == ["S1", "S2", "B1"])
        #expect(AgentsTile.backgroundStart(drawn) == 2)
        #expect(AgentsTile.backgroundStart([row("S1")]) == nil)
    }

    @Test func usageTileHidesWithoutReadings() {
        let none = UsagePanelData(providers: [.claude, .codex], windows: win(.claude, .none) + win(.codex, .none))
        #expect(!none.showsTile && none.shownProviders.isEmpty)
        #expect(!UsagePanelData(providers: [.claude], windows: []).showsTile)
    }

    @Test func providerWithoutReadingDropsOut() {
        let d = UsagePanelData(providers: [.claude, .codex], windows: win(.claude, .fresh) + win(.codex, .none))
        #expect(d.showsTile && d.shownProviders == [.claude])
        let past = UsagePanelData(providers: [.claude, .codex], windows: win(.claude, .none) + win(.codex, .pastReset, nil))
        #expect(past.shownProviders == [.codex])
    }

    @Test func staleNoteOncePerProvider() {
        let d = UsagePanelData(providers: [.claude, .codex], windows: win(.claude, .fresh) + win(.codex, .old))
        #expect(d.staleNote(.claude) == nil)
        #expect(d.staleNote(.codex)?.hasPrefix("Read ") == true)
    }

    @Test func resetLinesAreShort() {
        let live = win(.claude, .fresh)[0], past = win(.claude, .pastReset, nil)[0]
        #expect(UsageText.resetShort(live)?.hasPrefix("resets ") == true)
        #expect(UsageText.resetShort(past)?.hasPrefix("reset ") == true)
        #expect((UsageText.resetShort(past) ?? "").count <= 16)
    }

    @Test func idlePillIsIconOnlyAndDimmed() {
        let calm = UsagePanelData(providers: [.claude], windows: win(.claude, .fresh, 30))
        let hot = UsagePanelData(providers: [.claude], windows: win(.claude, .fresh, 90))
        #expect(AgentsPill.isIdle(running: 0, usage: calm))
        #expect(!AgentsPill.isIdle(running: 0, usage: hot))
        #expect(!AgentsPill.isIdle(running: 2, usage: calm))
        #expect(!AgentsPill.showsCount(running: 0) && AgentsPill.showsCount(running: 1))
        #expect(AgentsPill.idleOpacity < 1)
    }

    @Test func pillSlidesLeftOfTheTray() {
        let pill = CGRect(x: 800, y: 6, width: 60, height: 26)
        let tray = CGRect(x: 732, y: 12, width: 156, height: 48)
        let s = PillAvoidsTray.shift(pill: pill, tray: tray)
        #expect(s > 0 && pill.maxX - s == tray.minX - PillAvoidsTray.gap)
        #expect(PillAvoidsTray.shift(pill: pill, tray: nil) == 0)
        #expect(PillAvoidsTray.shift(pill: pill, tray: CGRect(x: 732, y: 300, width: 156, height: 48)) == 0)
        #expect(PillAvoidsTray.shift(pill: CGRect(x: 100, y: 6, width: 60, height: 26), tray: tray) == 0)
    }

    func place(_ n: String, me: Bool = false, online: Bool = true) -> PlaceRow {
        PlaceRow(id: n, name: n, folder: "/Users/x/true", isThisMac: me, online: online)
    }

    @Test func thisMacIsFirstAndOnlyOneWithTheFolderButton() {
        let rows = [place("Peer"), place("Me", me: true), place("Peer2")]
        let ordered = PlaceLayout.order(rows)
        #expect(ordered.map(\.name) == ["Me", "Peer", "Peer2"])
        #expect(ordered.filter(\.hasRevealButton).map(\.name) == ["Me"])
    }

    @Test func offlinePeerIsDimmedThisMacNever() {
        #expect(place("P", online: false).dimmed)
        #expect(!place("P").dimmed)
        #expect(!place("Me", me: true, online: false).dimmed)
        #expect(place("P", online: false).accessibilityText == "P, /Users/x/true, offline")
    }

    @Test func placesCollapseAtThree() {
        let four = [place("Me", me: true), place("A"), place("B"), place("C")]
        let v = PlaceLayout.visible(four, expanded: false)
        #expect(v.rows.count == 3 && v.hasDisclosure)
        #expect(PlaceLayout.visible(four, expanded: true).rows.count == 4)
        #expect(!PlaceLayout.visible(Array(four.prefix(3)), expanded: false).hasDisclosure)
    }

    static let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    // 2027-01-15 08:00 UTC

    @Test func offlineLineSaysWhenLastSeen() {
        var p = place("Alex's MacBook", online: false)
        p.lastSeen = Self.now.addingTimeInterval(-3600)   // 07:00 the same day
        #expect(p.offlineLine(now: Self.now, calendar: Self.utc) == "last seen 07:00")
        p.lastSeen = Self.now.addingTimeInterval(-7 * 86400)
        #expect(p.offlineLine(now: Self.now, calendar: Self.utc) == "last seen 8 Jan")
        p.lastSeen = nil
        #expect(p.offlineLine(now: Self.now, calendar: Self.utc) == "offline")
        #expect(place("P").offlineLine(now: Self.now, calendar: Self.utc) == nil)
        #expect(place("Me", me: true, online: false).offlineLine(now: Self.now, calendar: Self.utc) == nil)
    }

    @Test func accessibilityLabelIncludesLastSeen() {
        var p = place("Alex's MacBook", online: false)
        p.lastSeen = Self.now.addingTimeInterval(-3600)
        #expect(p.accessibilityText(now: Self.now, calendar: Self.utc) == "Alex's MacBook, /Users/x/true, last seen 07:00")
    }

    @Test func liveSourcePutsThisMacFirstWithPaneFolderAndNoPeers() {
        let rows = PlaceSource(macName: "the user's Mac", folder: "/Users/x/true").rows()
        #expect(rows.count == 1)
        #expect(rows[0].isThisMac && rows[0].name == "the user's Mac" && rows[0].folder == "/Users/x/true")
        #expect(PlaceSource.live(folder: "/a").rows().filter { !$0.isThisMac }.isEmpty)
        #expect(PlaceSource.live(folder: "/a").rows().first?.isThisMac == true)
    }

    @Test func folderIsTildeAbbreviated() {
        #expect(PlaceRow.shortFolder("/Users/example/Projects/true", home: "/Users/example") == "~/Projects/true")
        #expect(PlaceRow.shortFolder("/Users/example", home: "/Users/example") == "~")
        #expect(PlaceRow.shortFolder("/opt/x", home: "/Users/example") == "/opt/x")
        #expect(PlaceRow.shortFolder("") == "")
    }
}
