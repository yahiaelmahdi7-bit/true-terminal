import Foundation
import CryptoKit

enum DownloadError: Error, Equatable, LocalizedError {
    case lowDisk(needMB: Int64, haveMB: Int64)
    case badHash
    case http(Int)
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .lowDisk(let need, let have): "Not enough disk space: need \(need) MB free, have \(have) MB."
        case .badHash: "The download did not match the expected checksum and was deleted."
        case .http(let c): "Download failed (HTTP \(c))."
        case .cancelled: "Download cancelled."
        case .failed(let m): "Download failed: \(m)"
        }
    }
}

/// Downloads one pinned model into `directory`: temp file there, free-space check first, SHA-256 verified, atomic move.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let spaceMargin: Int64 = 200_000_000

    let model: WhisperModel
    let source: URL
    let directory: URL
    let defaults: UserDefaults
    let freeSpace: @Sendable (URL) -> Int64
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var cont: CheckedContinuation<URL, Error>?
    private var part: URL?
    private var failure: Error?
    private var onProgress: (@Sendable (Double) -> Void)?

    init(model: WhisperModel, source: URL? = nil, directory: URL = DictationModels.downloadDir,
         defaults: UserDefaults = .standard,
         freeSpace: @escaping @Sendable (URL) -> Int64 = ModelDownloader.systemFreeSpace) {
        self.model = model; self.source = source ?? model.url; self.directory = directory
        self.defaults = defaults; self.freeSpace = freeSpace
    }

    static let systemFreeSpace: @Sendable (URL) -> Int64 = { url in
        var dir = url
        while !FileManager.default.fileExists(atPath: dir.path), dir.pathComponents.count > 1 { dir.deleteLastPathComponent() }
        let v = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? Int64.max
    }

    var destination: URL { directory.appendingPathComponent(model.file) }

    /// Returns the final model URL and records it as `dictation.modelPath`. Throws `DownloadError`.
    func run(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let need = model.size + Self.spaceMargin, have = freeSpace(directory)
        if have < need { throw DownloadError.lowDisk(needMB: need / 1_000_000, haveMB: have / 1_000_000) }
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { throw DownloadError.failed(error.localizedDescription) }
        onProgress = progress
        let s = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        let t = s.downloadTask(with: source)
        lock.withLock { session = s; task = t }
        defer { s.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
                lock.withLock { cont = c }
                t.resume()
            }
        } onCancel: { self.cancel() }
    }

    func cancel() {
        lock.lock(); let t = task; lock.unlock()
        t?.cancel()
    }

    // MARK: delegate (serial queue)

    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten w: Int64, totalBytesExpectedToWrite e: Int64) {
        let total = e > 0 ? e : model.size
        onProgress?(min(1, Double(w) / Double(total)))
    }

    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let h = t.response as? HTTPURLResponse, h.statusCode != 200 { failure = DownloadError.http(h.statusCode); return }
        let p = directory.appendingPathComponent(".\(model.file).\(UUID().uuidString).part")
        do { try FileManager.default.moveItem(at: location, to: p); part = p }
        catch { failure = DownloadError.failed(error.localizedDescription) }
    }

    func urlSession(_ s: URLSession, task t: URLSessionTask, didCompleteWithError error: Error?) {
        let outcome: Result<URL, Error>
        if let error {
            outcome = .failure((error as? URLError)?.code == .cancelled ? DownloadError.cancelled : DownloadError.failed(error.localizedDescription))
        } else if let failure {
            outcome = .failure(failure)
        } else if let part {
            outcome = finish(part)
        } else {
            outcome = .failure(DownloadError.failed("no data"))
        }
        if case .failure = outcome, let part { try? FileManager.default.removeItem(at: part) }
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        switch outcome {
        case .success(let u): c?.resume(returning: u)
        case .failure(let e): c?.resume(throwing: e)
        }
    }

    private func finish(_ part: URL) -> Result<URL, Error> {
        guard let digest = Self.sha256(of: part) else { return .failure(DownloadError.failed("could not read download")) }
        guard digest == model.sha256 else { return .failure(DownloadError.badHash) }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: part)
            } else {
                try FileManager.default.moveItem(at: part, to: destination)
            }
        } catch { return .failure(DownloadError.failed(error.localizedDescription)) }
        defaults.set(destination.path, forKey: DictationSettings.modelKey)
        return .success(destination)
    }

    static func sha256(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
