import Foundation
import Testing
@testable import True

@Suite struct SeatRuntimeTests {
    @Test func unknownSignInIsNeverSignedIn() {
        #expect(!SeatSignIn.unknown.isSignedIn)
        #expect(!SeatSignIn.notSignedIn.isSignedIn)
        #expect(SeatSignIn.signedIn.isSignedIn)
        #expect(SeatSignIn.from(nil, provider: .claude) == .unknown)
        #expect(SeatSignIn.from(.notWorking, provider: .claude) == .unknown)
        #expect(SeatSignIn.from(.notInstalled, provider: .codex) == .unknown)
        #expect(SeatSignIn.from(.notSignedIn, provider: .codex) == .notSignedIn)
        #expect(SeatSignIn.from(.ready, provider: .claude) == .signedIn)
        // Codex Ready only means "not seen logged out", so it stays Unknown.
        #expect(SeatSignIn.from(.ready, provider: .codex) == .unknown)
    }

    @Test func configDirDefaultLeavesLaunchByteIdentical() {
        for seat in [ClaudeSeat() as any SeatProviding, CodexSeat()] {
            let argv = [seat.kind.rawValue, "--flag", "it's"]
            #expect(seat.shellCommand(argv: argv, seatConfigDir: nil) == seat.shellCommand(argv: argv))
        }
    }

    @Test func configDirIsExportedAndQuoted() {
        let dir = URL(fileURLWithPath: "/tmp/seat home/it's")
        let claude = ClaudeSeat().shellCommand(argv: ["claude"], seatConfigDir: dir)
        #expect(claude.hasPrefix(#"export CLAUDE_CONFIG_DIR='/tmp/seat home/it'\''s'; "#))
        let codex = CodexSeat().shellCommand(argv: ["codex"], seatConfigDir: dir)
        #expect(codex.hasPrefix(#"export CODEX_HOME='/tmp/seat home/it'\''s'; "#))
        #expect(codex.hasSuffix(CodexSeat().shellCommand(argv: ["codex"])))
    }

    @Test func missingProgramSnapshotIsEmptyAndDefaultsChangeNothing() {
        let finder = ProgramFinder(shell: "/bin/sh", environment: ["HOME": "/nonexistent", "PATH": ""], roots: [],
                                   tailscaleCopies: [], runner: { _, _, _, _ in nil })
        let info = ClaudeSeat().runtimeSnapshot(finder: finder)
        #expect(info == SeatRuntimeInfo(installed: false, version: nil, signIn: .unknown, limitedUntil: nil))
        #expect(info.limitLabel == nil)
        #expect(!info.signIn.isSignedIn)
    }

    @Test func limitLabelOnlyWhenADateIsGiven() {
        let info = SeatRuntimeInfo(installed: true, version: "x", limitedUntil: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(info.limitLabel?.hasPrefix("Limited until ") == true)
    }

    @Test func probeReadsVersionOffTheCallerAndSnapshotNeverStartsAProcess() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("seat-rt-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let exe = dir.appendingPathComponent("codex")
        try "#!/bin/sh\necho 'codex-cli 9.9.9'\n".write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        let finder = ProgramFinder(shell: "/bin/sh", environment: ["HOME": dir.path, "PATH": dir.path], roots: [dir.path],
                                   tailscaleCopies: [])
        let quick = CodexSeat().runtimeSnapshot(finder: finder)
        #expect(quick.installed && quick.version == nil)
        let probed = await CodexSeat().probeRuntime(finder: finder)
        #expect(probed.installed && probed.version == "codex-cli 9.9.9" && probed.signIn == .unknown)
    }
}

/// The card's live "Limited until": structured windows only, and only for the account they were read from.
@Suite struct SeatLiveLimitTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    func window(_ p: UsageProvider, used: Double, resetIn: TimeInterval) -> UsageWindow {
        UsageWindow(provider: p, kind: .fiveHour, usedPercent: used, resetsAt: Self.now.addingTimeInterval(resetIn),
                    windowMins: 300, readAt: Self.now, state: .fresh)
    }

    @Test func defaultAccountAtItsLimitIsLimitedUntilTheReset() {
        let ws = [window(.claude, used: 100, resetIn: 3600), window(.codex, used: 10, resetIn: 3600)]
        #expect(SeatRuntimeInfo.liveLimit(provider: .claude, account: nil, windows: ws, now: Self.now) == Self.now.addingTimeInterval(3600))
        #expect(SeatRuntimeInfo.liveLimit(provider: .codex, account: nil, windows: ws, now: Self.now) == nil)
    }

    @Test func aSeatOnAnotherAccountNeverShowsTheDefaultAccountsLimit() {
        let ws = [window(.claude, used: 100, resetIn: 3600)]
        #expect(SeatRuntimeInfo.liveLimit(provider: .claude, account: "work", windows: ws, now: Self.now) == nil)
    }
}
