import Foundation
import Testing
@testable import True

@Suite @MainActor struct CodexHookTests {
    final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [PaneEvent] = []
        var events: [PaneEvent] { lock.lock(); defer { lock.unlock() }; return storage }
        func add(_ e: PaneEvent) { lock.lock(); storage.append(e); lock.unlock() }
    }
    @Test func recordedHooksRoundTripThroughRealSocket() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hook-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("forward.py")
        try AgentHooks.forwarder(socketPath: "/unused").write(to: path, atomically: true, encoding: .utf8)
        let socket = "/tmp/tc-\(UUID().uuidString.prefix(8)).sock", pane = UUID(), received = Received()
        let listener = AgentEventSocket(path: socket) { received.add($0) }
        #expect(listener.start()); defer { listener.stop() }
        let rows = try #require(try JSONSerialization.jsonObject(with: Data(CodexRecordings.payloads.utf8)) as? [[String: Any]])
        for row in rows {
            let p = Process(), input = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["python3", path.path]
            p.environment = ["PATH": "/usr/bin:/bin:/opt/homebrew/bin", "TRUE_PROVIDER": "codex", "TRUE_PANE_ID": pane.uuidString, "TRUE_EVENTS_SOCK": socket]
            p.standardInput = input; p.standardOutput = Pipe()
            try p.run(); input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: row)); try input.fileHandleForWriting.close()
            p.waitUntilExit(); #expect(p.terminationStatus == 0)
        }
        #expect(await eventually { received.events.count == rows.count })
        #expect(Set(received.events.map(\.kind)) == Set([.session, .progress, .need, .stop, .idle]))
        #expect(received.events.allSatisfy { $0.transcript == nil })
        #expect(received.events.first { $0.kind == .need }?.detail == "printf APPROVAL_OK")
    }
    @Test func unknownEventsAndProviderAreDeterministic() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hook-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let forwarder = AgentHooks.forwarder(socketPath: "/unused")
        let code = try #require(forwarder.components(separatedBy: "try:\n    main()").first)
        let script = code + #"""

        os.environ['TRUE_PROVIDER'] = 'codex'
        for name in ['FutureHook', 'StopFailure', 'Notification', 'SessionEnd', 'PostToolUse', 'PreCompact', 'SubagentStop']:
            assert classify({'hook_event_name': name}) is None
        assert classify({'hook_event_name': 'Interrupt'}) == ('idle', '')
        os.environ['TRUE_PROVIDER'] = 'future-provider'
        assert classify({'hook_event_name': 'StopFailure', 'error': 'bad'}) == ('error', 'bad')
        """#
        let path = dir.appendingPathComponent("test.py")
        try script.write(to: path, atomically: true, encoding: .utf8)
        let p = Process(), err = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["python3", path.path]
        p.standardError = err; try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        #expect(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains("unknown seat provider"))
    }
}
