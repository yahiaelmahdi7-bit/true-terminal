import Foundation

/// Run 36a (A4): a background builder's `stream.jsonl` → condensed activity items, so a peer job run by a builder
/// shows its steps like a pane does. The parser is pure; the tailer owns the file.
enum PeerStream {
    /// The items one stream line stands for. Tool input follows the same share-level table as pane hooks.
    static func items(line: String, at: Date, level: PeerShare) -> [PeerActivityItem] {
        guard level != .status, let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let type = o["type"] as? String else { return [] }
        let t = Int(at.timeIntervalSince1970)
        switch type {
        case "assistant":
            guard let content = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return [] }
            return content.compactMap { block -> PeerActivityItem? in
                switch block["type"] as? String {
                case "text":
                    let limit = level == .everything ? PeerActivityItem.maxLong : PeerActivityItem.maxText
                    let text = PeerMask.text((block["text"] as? String) ?? "", limit: limit)
                    return text.isEmpty ? nil : PeerActivityItem(t: t, kind: .assistant, text: text)
                case "tool_use":
                    guard let name = block["name"] as? String, !name.isEmpty else { return nil }
                    let input = ((block["input"] as? [String: Any]) ?? [:]).compactMapValues { $0 as? String }
                    let s = ToolSummary.summarize(tool: name, input: input)
                    let d = PeerEngine.safeDetail(tool: name, detail: s.detail, level: level)
                    return PeerActivityItem(t: t, kind: .tool, text: PeerMask.firstLine(d.isEmpty ? name : "\(name) · \(d)"))
                default: return nil
                }
            }
        case "result":
            guard o["is_error"] as? Bool == true else { return [] }
            let why = PeerMask.text((o["result"] as? String) ?? "", limit: 400)
            return [PeerActivityItem(t: t, kind: .status, text: why.isEmpty ? "Ended with an error" : "Ended with an error: \(why)")]
        default: return []
        }
    }
}

/// Follows a file as it grows and hands each complete new line to `onLines`. If the file is deleted or renamed away
/// (`builder resume` rotates `stream.jsonl`) it waits for a new file at the same path and starts that one from the top.
final class PeerStreamTailer: @unchecked Sendable {
    private let path: String
    private let onLines: @Sendable ([String]) -> Void
    private let queue = DispatchQueue(label: "true.peers.stream")
    private var source: DispatchSourceFileSystemObject?
    private var offset: UInt64 = 0
    private var partial = Data()
    private var stopped = false
    private var retries = 0
    static let maxRetries = 60

    init(path: String, onLines: @escaping @Sendable ([String]) -> Void) {
        self.path = path; self.onLines = onLines
        queue.async { [self] in open() }
    }

    func stop() {
        queue.async { [self] in stopped = true; source?.cancel(); source = nil }
    }

    /// Tests: wait for everything queued so far.
    func sync() { queue.sync {} }

    private func open() {
        guard !stopped else { return }
        let fd = Foundation.open(path, O_EVTONLY)
        guard fd >= 0 else {
            retries += 1
            if retries <= Self.maxRetries { queue.asyncAfter(deadline: .now() + 1) { [self] in open() } }
            return
        }
        retries = 0; offset = 0; partial = Data()
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            self.readNew()
            if src.data.contains(.delete) || src.data.contains(.rename) {
                src.cancel(); self.source = nil
                self.queue.asyncAfter(deadline: .now() + 0.2) { [self] in open() }
            }
        }
        src.setCancelHandler { Foundation.close(fd) }
        source?.cancel()
        source = src
        src.resume()
        readNew()
    }

    private func readNew() {
        guard let h = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size < offset { offset = 0; partial = Data() }       // truncated in place
        try? h.seek(toOffset: offset)
        guard let data = try? h.read(upToCount: 4 * 1024 * 1024), !data.isEmpty else { return }
        offset += UInt64(data.count)
        partial.append(data)
        var lines: [String] = []
        while let nl = partial.firstIndex(of: 10) {
            lines.append(String(decoding: partial[partial.startIndex..<nl], as: UTF8.self))
            partial = Data(partial[(nl + 1)...])
        }
        if !lines.isEmpty { onLines(lines) }
    }
}
