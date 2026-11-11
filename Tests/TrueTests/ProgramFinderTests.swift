import Foundation
import Testing
@testable import True

@Suite struct ProgramFinderTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("finder-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func executable(_ url: URL, _ body: String = "exit 0") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @Test func strippedPATHFindsHomebrewAndAppCopy() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let brew = dir.appendingPathComponent("opt/homebrew/bin")
        let app = dir.appendingPathComponent("Applications/Tailscale.app/Contents/MacOS/Tailscale")
        try executable(brew.appendingPathComponent("claude"))
        try executable(app)
        let finder = ProgramFinder(environment: ["PATH": "/usr/bin:/bin"], roots: [brew.path], tailscaleCopies: [app.path])
        #expect(finder.resolve("claude") == brew.path + "/claude")
        #expect(finder.resolve("tailscale") == app.path)
        let live = ProgramFinder(environment: ["PATH": "/usr/bin:/bin", "HOME": "/fake"])
        #expect(live.candidates("git").contains("/opt/homebrew/bin/git"))
        #expect(live.candidates("git").contains("/usr/local/bin/git"))
        #expect(live.candidates("tailscale").contains("/Applications/Tailscale.app/Contents/MacOS/Tailscale"))
        #expect(finder.resolve("../claude") == nil)
    }

    @Test @MainActor func noisyLoginIsReadOnceOffMainAndCachedUntilFailure() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let bin = dir.appendingPathComponent("custom bin")
        try executable(bin.appendingPathComponent("git"))
        final class Calls: @unchecked Sendable {
            let lock = NSLock(); var shell = 0; var onMain = false
            func record() { lock.lock(); shell += 1; onMain = onMain || Thread.isMainThread; lock.unlock() }
            func snapshot() -> (Int, Bool) { lock.lock(); defer { lock.unlock() }; return (shell, onMain) }
        }
        let calls = Calls()
        let finder = ProgramFinder(shell: "/fake/shell", environment: [:], roots: [], tailscaleCopies: [], runner: { exe, _, _, _ in
            if exe == "/fake/shell" {
                calls.record()
                return .init(status: 0, text: "rc noise\n\(ProgramFinder.begin)\n\(bin.path)\n\(ProgramFinder.end)\nmore noise", timedOut: false)
            }
            return .init(status: 0, text: "version", timedOut: false)
        })
        finder.start(); finder.start()
        #expect(await eventually { finder.cachedResult("tailscale") != nil })
        #expect(finder.resolve("git") == bin.path + "/git")
        #expect(calls.snapshot().0 == 1)
        #expect(!calls.snapshot().1)
        try FileManager.default.removeItem(at: bin.appendingPathComponent("git"))
        #expect(finder.resolve("git") == bin.path + "/git") // no polling or filesystem recheck
        finder.failedToRun("git")
        #expect(await eventually { finder.cachedResult("git")?.state == .notInstalled })
        #expect(calls.snapshot().0 == 2)
    }

    @Test @MainActor func realShellMarkersIgnoreRCNoiseAndKeepSpaces() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let bin = dir.appendingPathComponent("custom bin")
        let shell = dir.appendingPathComponent("shell")
        try executable(bin.appendingPathComponent("git"))
        try executable(shell, "echo 'rc noise'\nexport PATH='\(bin.path)'\n/bin/sh -c \"$2\"\necho 'more rc noise'")
        let finder = ProgramFinder(shell: shell.path, environment: [:], roots: [], tailscaleCopies: [])
        finder.start()
        #expect(await eventually { finder.cachedResult("tailscale") != nil })
        #expect(finder.cachedResult("git")?.path == bin.path + "/git")
        #expect(finder.path == bin.path)
    }

    @Test @MainActor func sleepingRCDoesNotBlockLaunchAndIsKilledAtCap() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let shell = dir.appendingPathComponent("shell")
        let pidFile = dir.appendingPathComponent("child")
        try executable(shell, "trap '' TERM\n/bin/sleep 10 &\nchild=$!\necho $child > '\(pidFile.path)'\nwait $child")
        let finder = ProgramFinder(shell: shell.path, environment: [:], roots: [], tailscaleCopies: [])
        let start = Date()
        finder.start()
        #expect(Date().timeIntervalSince(start) < 1)
        #expect(await eventually { finder.cachedResult("tailscale") != nil })
        #expect(Date().timeIntervalSince(start) < 8)
        #expect(finder.cachedResult("git")?.state == .notInstalled)
        if let pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap({ Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
            #expect(await eventually { kill(pid, 0) != 0 })
        } else { Issue.record("shell did not write its child pid") }
    }

    @Test @MainActor func launchctlThenFixedRootsFallback() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        try executable(dir.appendingPathComponent("codex"))
        for launchctlWorks in [true, false] {
            let finder = ProgramFinder(shell: "/fake", environment: [:], roots: launchctlWorks ? [] : [dir.path], tailscaleCopies: [], runner: { exe, _, _, _ in
                if exe == "/fake" { return .init(status: 0, text: "not framed PATH", timedOut: false) }
                if exe == "/bin/launchctl" { return .init(status: launchctlWorks ? 0 : 1, text: dir.path, timedOut: false) }
                return .init(status: 0, text: "ok", timedOut: false)
            })
            finder.start()
            #expect(await eventually { finder.cachedResult("tailscale") != nil })
            #expect(finder.resolve("codex") == dir.path + "/codex")
        }
    }

    @Test func fakeProgramsGivePlainStatesAndDoNotConfuseBrokenAuthWithMissingLogin() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        // A fake `security` stands in for the Keychain: "not found" (44) is what lets a logout read as Not signed in.
        try executable(dir.appendingPathComponent("security"), "exit 44")
        let finder = ProgramFinder(environment: [:], roots: [dir.path], tailscaleCopies: [], probeTimeout: 30,
                                   securityPath: dir.appendingPathComponent("security").path)
        #expect(finder.inspect("claude").line == "Not installed")
        try executable(dir.appendingPathComponent("claude"), "exit 3")
        #expect(finder.inspect("claude").line == "Installed but not working")
        try executable(dir.appendingPathComponent("claude"), "if [ \"$1\" = '--version' ]; then exit 0; fi\nprintf '%s' '{\"loggedIn\":false}'; exit 1")
        #expect(finder.inspect("claude").line == "Not signed in")
        try executable(dir.appendingPathComponent("codex"), "if [ \"$1\" = '--version' ]; then exit 0; fi\necho 'Not logged in' >&2; exit 1")
        #expect(finder.inspect("codex").line == "Not signed in")
        try executable(dir.appendingPathComponent("codex"), "if [ \"$1\" = '--version' ]; then exit 0; fi\necho 'Unreadable config' >&2; exit 1")
        #expect(finder.inspect("codex").state == .ready)
        try executable(dir.appendingPathComponent("tailscale"), "if [ \"$1\" = '--version' ]; then exit 0; fi\nprintf '%s' '{\"BackendState\":\"NeedsLogin\"}'")
        #expect(finder.inspect("tailscale").line == "Not signed in")
        try executable(dir.appendingPathComponent("tailscale"), "if [ \"$1\" = '--version' ]; then exit 0; fi\nexit 1")
        #expect(finder.inspect("tailscale").state == .notWorking)
        // gh auth status contacts GitHub: a working binary is all an offline check can establish.
        try executable(dir.appendingPathComponent("gh"), "[ \"$1\" = '--version' ]")
        #expect(finder.inspect("gh").state == .ready)
    }

    @Test func versionProbeIsBoundedEvenIfProgramIgnoresTermination() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let exe = dir.appendingPathComponent("git")
        try executable(exe, "trap '' TERM\nexec /bin/sleep 10")
        let start = Date()
        let finder = ProgramFinder(environment: [:], roots: [dir.path], tailscaleCopies: [])
        #expect(finder.inspect("git").state == .notWorking)
        #expect(Date().timeIntervalSince(start) < 5)
    }
}
