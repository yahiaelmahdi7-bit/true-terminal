import AppKit
import SwiftUI
import Testing
@testable import True

@Suite struct PaneStripRuleTests {
    @Test func modeBoundary() {
        #expect(PaneStrip.mode(width: PaneStrip.minWidth) == .strip)
        #expect(PaneStrip.mode(width: PaneStrip.minWidth - 0.5) == .collapsed)
        #expect(PaneStrip.mode(width: 0) == .collapsed)
        #expect(PaneStrip.mode(width: 2000) == .strip)
    }

    /// On a 1440 pt window: two panes across stay, three collapse (dividers are 1 pt).
    @Test func thresholdOn1440Window() {
        #expect(PaneStrip.mode(width: (1440 - 1) / 2) == .strip)
        #expect(PaneStrip.mode(width: (1440 - 2) / 3) == .collapsed)
    }

    @Test func pillCarriesProjectOnlyWhenAPaneIsCollapsed() {
        #expect(PaneStrip.pillShowsProject(widths: [720, 719]) == false)
        #expect(PaneStrip.pillShowsProject(widths: [720, 480]) == true)
        #expect(PaneStrip.pillShowsProject(widths: [480, 480, 480]) == true)
        #expect(PaneStrip.pillShowsProject(widths: []) == true)
    }

    @Test func widenRestoresStrip() {
        #expect(PaneStrip.mode(width: 480) == .collapsed)
        #expect(PaneStrip.mode(width: 720) == .strip)
    }

    @Test func foldersAreReadOncePerRepo() {
        let panes: [(folder: String, width: CGFloat)] = [("/a/true", 700), ("/a/true", 700), ("/b/site", 700), ("/c/hidden", 400), ("", 700)]
        #expect(PaneStrip.foldersToRead(panes) == ["/a/true", "/b/site"])   // shared repo once, collapsed pane skipped, blank skipped
        #expect(PaneStrip.foldersToRead([]) == [])
    }

    @Test func readAllCallsReaderOncePerFolder() {
        var calls: [String] = []
        let out = PaneStripStore.readAll(["/a", "/b", "/a", "/b", "/a"]) { f in calls.append(f); return PaneStripInfo() }
        #expect(calls == ["/a", "/b"])
        #expect(Set(out.keys) == ["/a", "/b"])
    }

    @Test func closedPaneOrChangedFolderDropsOutOfTheReadSet() {
        let before = PaneStrip.foldersToRead([("/a", 700), ("/b", 700)])
        let afterClose = PaneStrip.foldersToRead([("/a", 700)])
        let afterCd = PaneStrip.foldersToRead([("/a", 700), ("/c", 700)])
        #expect(before == ["/a", "/b"]); #expect(afterClose == ["/a"]); #expect(afterCd == ["/a", "/c"])
        let out = PaneStripStore.readAll(afterClose) { _ in PaneStripInfo() }
        #expect(out["/b"] == nil)
    }

    @Test func names() {
        #expect(PaneStrip.folderName("/Users/example/Projects/true", home: "/Users/example") == "true")
        #expect(PaneStrip.folderName("/Users/example", home: "/Users/example") == "~")
        #expect(PaneStrip.teammateText(["Alex"]) == "Alex")
        #expect(PaneStrip.teammateText(["Alex", "Sara", "Nour"]) == "Alex +2")
        #expect(PaneStrip.teammateText([]) == nil)
        let rows = [PlaceRow(id: "me", name: "Mac", folder: "", isThisMac: true), PlaceRow(id: "a", name: "Alex", folder: ""),
                    PlaceRow(id: "b", name: "Sara", folder: "", online: false)]
        #expect(PaneStrip.teammates(rows) == ["Alex"])
    }

    @Test func cleanRepoShowsNoCounts() {
        #expect(PaneGitStatus(isRepo: true, branch: "main", added: 0, removed: 0, files: 0).showsCounts == false)
        #expect(PaneGitStatus(isRepo: true, branch: "main", added: 3, removed: 0, files: 1).showsCounts)
        #expect(PaneGitStatus(isRepo: true, branch: "main", added: 0, removed: 2, files: 1).showsCounts)
    }

    @Test func stripCostsOneLine() {
        let i = PaneStrip.insets(Theme.paneInsets, strip: true)
        #expect(i.top - Theme.paneInsets.top <= 18)
        #expect(PaneStrip.insets(Theme.paneInsets, strip: false).top == Theme.paneInsets.top)
    }
}

/// Pane strip stills, offscreen. Output: .out/stills/pane-strip/. Not merged until the user OKs them.
@MainActor
@Suite struct PaneStripStillsTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(".out/stills/pane-strip")
    typealias S = AgentsStillsTests
    let t = S()

    func snap<V: View>(_ name: String, width: CGFloat, @ViewBuilder _ content: () -> V) throws {
        try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        for (tag, scheme, appearance) in [("light", ColorScheme.light, NSAppearance.Name.aqua), ("dark", ColorScheme.dark, NSAppearance.Name.darkAqua)] {
            NSAppearance.current = NSAppearance(named: appearance)
            let view = content().frame(width: width).background(scheme == .dark ? Theme.Token.bg0 : Color(white: 0.93)).environment(\.colorScheme, scheme)
            let r = ImageRenderer(content: view); r.scale = 2
            let tiff = try #require(r.nsImage?.tiffRepresentation)
            let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try png.write(to: Self.root.appendingPathComponent("\(name)-\(tag).png"))
        }
    }

    static let repoWithChanges = PaneStripInfo(git: PaneGitStatus(isRepo: true, branch: "builder/pane-strip", added: 148, removed: 22, files: 5), places: [S.me])
    static let repoWithTeammate = PaneStripInfo(git: PaneGitStatus(isRepo: true, branch: "main", added: 0, removed: 0, files: 0),
                                                places: [PaneStripStillsTests.me("~/Projects/site"), S.peer("Alex", "~/code/site")])
    static func me(_ f: String) -> PlaceRow { var r = S.me; r.folder = NSHomeDirectory() + f.dropFirst(1); return r }
    static let notRepo = PaneStripInfo()

    /// A terminal pane: True black, the strip in its top margin, a few prompt lines under it.
    func pane(width: CGFloat, folder: String?, info: PaneStripInfo, focused: Bool = true) -> some View {
        let strip = folder != nil
        let insets = PaneStrip.insets(Theme.paneInsets, strip: strip)
        return ZStack(alignment: .topLeading) {
            Color.black
            VStack(alignment: .leading, spacing: 2) {
                ForEach(["~ % git status", "On branch main", "nothing to commit", "~ % ▍"], id: \.self) {
                    Text($0).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.text)
                }
            }.padding(insets).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let folder {
                PaneStripBar(folder: folder, info: info).padding(.leading, insets.leading).padding(.top, 2)
            }
        }
        .frame(width: width, height: 150).opacity(focused ? 1 : 0.6)
    }

    func window(width: CGFloat, @ViewBuilder _ panes: () -> some View, trailing: some View = EmptyView()) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            AgentsPill(running: 1, needsYou: false, idle: false, solid: true).padding(.trailing, 10).padding(.top, 6)
            HStack(alignment: .top, spacing: 1) { panes() }
        }.frame(width: width, alignment: .topTrailing).background(Color.black)
    }

    func panel(showsProject: Bool, status: PaneGitStatus, places: [PlaceRow]) -> some View {
        PanePanelView(status: status, solid: true, agents: [t.seat("Main")], usage: t.calm, places: places, placesNow: S.placeNow, placesCalendar: S.utc,
                      showsProject: showsProject)
    }

    @Test func stills() throws {
        // a. one pane on a repo with changes
        try snap("a-one-pane", width: 720) { window(width: 720) { pane(width: 720, folder: "/Users/example/Projects/true", info: Self.repoWithChanges) } }
        // b. two panes, two repos: one with a teammate, one with +N −M. The top panel drops the project tiles.
        try snap("b-two-panes", width: 1440) {
            window(width: 1440) {
                pane(width: 719.5, folder: "/Users/example/Projects/true", info: Self.repoWithChanges)
                pane(width: 719.5, folder: "/Users/example/Projects/site", info: Self.repoWithTeammate, focused: false)
            }
        }
        try snap("b-two-panes-top-panel", width: 312) { panel(showsProject: false, status: Self.repoWithChanges.git, places: [S.me]).padding(8) }
        // c. three across, collapsed: no strips; the top panel carries the focused pane's project.
        try snap("c-three-panes-collapsed", width: 1440) {
            window(width: 1440) {
                ForEach(0..<3, id: \.self) { i in pane(width: 479.3, folder: nil, info: PaneStripInfo(), focused: i == 0) }
            }
        }
        try snap("c-three-panes-top-panel", width: 312) { panel(showsProject: true, status: Self.repoWithChanges.git, places: [S.me]).padding(8) }
        // d. popover opened from a pane strip: the project sections only, scoped to that pane's folder.
        try snap("d-strip-popover", width: 720) {
            VStack(alignment: .leading, spacing: 4) {
                pane(width: 720, folder: "/Users/example/Projects/site", info: Self.repoWithTeammate).frame(height: 40, alignment: .top).clipped()
                HStack { PanePanelView(status: Self.repoWithTeammate.git, editors: [PaneEditor(id: "x", name: "Cursor", url: URL(fileURLWithPath: "/"))],
                                       chosenEditor: PaneEditor(id: "x", name: "Cursor", url: URL(fileURLWithPath: "/")), shadow: true, solid: true,
                                       places: Self.repoWithTeammate.places, placesNow: S.placeNow, placesCalendar: S.utc, showsProject: true).padding(.leading, 12)
                    Spacer() }
            }.padding(.bottom, 20).background(Color.black)
        }
        // e. a folder that is not a git repo: folder name only.
        try snap("e-not-git", width: 720) { window(width: 720) { pane(width: 720, folder: NSHomeDirectory() + "/Downloads", info: Self.notRepo) } }
    }
}
