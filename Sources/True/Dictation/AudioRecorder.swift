@preconcurrency import AVFoundation

/// Where clips live: ~/.true/dictation, 0700. Stale clips are swept at launch (a file delete, not a timer).
enum DictationFiles {
    static var dir: URL { URL(fileURLWithPath: NSHomeDirectory() + "/.true/dictation", isDirectory: true) }
    static func ensureDir(_ d: URL) {
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    static func sweep(_ d: URL = dir) {
        for f in (try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "wav" {
            try? FileManager.default.removeItem(at: f)
        }
    }
}

/// Mic capture on an AVAudioEngine tap, lifted from the removed voice recorder. Differences: no
/// voice processing / AEC / ducking (dictation must not turn other apps down), a 5 min hard cap, and an
/// engine-configuration-change callback (device changed mid-hold: caller discards). The tap runs on a real-time
/// thread, so state is lock-guarded and the type is @unchecked Sendable.
final class AudioRecorder: @unchecked Sendable {
    static let maxSeconds = 300.0
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sourceRate: Double = 48_000
    private var running = false
    private var capped = false
    private var configObserver: NSObjectProtocol?
    /// Fired (any thread) when the audio device/format changes mid-recording.
    var onConfigChange: (@Sendable () -> Void)?
    /// Fired (any thread) once when the 5 min cap is reached.
    var onCap: (@Sendable () -> Void)?

    static var isAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    func start() throws {
        lock.lock(); samples.removeAll(keepingCapacity: true); capped = false; lock.unlock()
        let input = engine.inputNode
        guard let format = input.safeTapFormat() else { throw AudioSetupError.inputNotReady }
        lock.lock(); sourceRate = format.sampleRate; lock.unlock()
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in self?.absorb(buffer) }
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); throw error }
        running = true
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in self?.onConfigChange?() }
    }

    private func absorb(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        let chunk = Array(UnsafeBufferPointer(start: channels[0], count: n))
        lock.lock()
        let room = Int(Self.maxSeconds * sourceRate) - samples.count
        if room > 0 { samples.append(contentsOf: chunk.prefix(room)) }
        let hit = room <= n && !capped
        if hit { capped = true }
        lock.unlock()
        if hit { onCap?() }
    }

    /// Stop the mic. Returns 16 kHz mono samples (not yet written anywhere) and the clip length.
    func stop() -> (samples: [Float], seconds: Double) {
        guard running else { return ([], 0) }
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        lock.lock(); let raw = samples; let rate = sourceRate; samples = []; lock.unlock()
        let mono16k = AudioLevel.normalized(AudioResampler.to16kMono(raw, sourceRate: rate))
        return (mono16k, Double(mono16k.count) / 16_000)
    }

    /// Stop and throw the audio away.
    func cancel() { _ = stop() }
}

// MARK: - Resampling

/// Sample-rate conversion to 16 kHz mono via `AVAudioConverter` (proper anti-aliasing, unlike a
/// naive decimation). Input is already channel-0 mono at the hardware rate.
enum AudioResampler {
    static func to16kMono(_ input: [Float], sourceRate: Double) -> [Float] {
        guard !input.isEmpty else { return [] }
        guard sourceRate != 16_000 else { return input }
        guard sourceRate > 0,
              let src = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceRate, channels: 1, interleaved: false),
              let dst = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: src, to: dst),
              let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(input.count)) else {
            return input
        }
        inBuf.frameLength = AVAudioFrameCount(input.count)
        input.withUnsafeBufferPointer { p in
            inBuf.floatChannelData![0].update(from: p.baseAddress!, count: input.count)
        }

        let ratio = 16_000 / sourceRate
        let capacity = AVAudioFrameCount(Double(input.count) * ratio + 4096)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: capacity) else { return input }

        // The pull block is typed @Sendable; a boxed flag serves it the buffer exactly once.
        final class OneShot: @unchecked Sendable { var used = false }
        let oneShot = OneShot()
        var error: NSError?
        converter.convert(to: outBuf, error: &error) { _, status in
            if oneShot.used { status.pointee = .endOfStream; return nil }
            oneShot.used = true; status.pointee = .haveData; return inBuf
        }
        if error != nil { return input }

        let n = Int(outBuf.frameLength)
        let out = outBuf.floatChannelData![0]
        return Array(UnsafeBufferPointer(start: out, count: n))
    }
}

// MARK: - WAV writing

/// Writes 16-bit PCM mono WAV (little-endian, which Apple silicon is natively) to a temp file.
enum WavWriter {
    static func write(_ samples: [Float], sampleRate: Int, dir: URL = DictationFiles.dir) -> URL? {
        guard !samples.isEmpty else { return nil }
        DictationFiles.ensureDir(dir)
        let url = dir.appendingPathComponent("clip-\(UUID().uuidString).wav")

        let channels = 1, bits = 16
        let byteRate = sampleRate * channels * bits / 8
        let blockAlign = channels * bits / 8
        let dataBytes = samples.count * 2

        var data = Data(capacity: 44 + dataBytes)
        func put<T>(_ value: T) { var v = value; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }

        data.append(contentsOf: Array("RIFF".utf8))
        put(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        put(UInt32(16))                 // PCM header size
        put(UInt16(1))                  // PCM format
        put(UInt16(channels))
        put(UInt32(sampleRate))
        put(UInt32(byteRate))
        put(UInt16(blockAlign))
        put(UInt16(bits))
        data.append(contentsOf: Array("data".utf8))
        put(UInt32(dataBytes))
        for s in samples {
            let clamped = max(-1, min(1, s))
            put(Int16(clamped * 32_767))
        }

        // 0600 from the first byte: create empty with the mode, then write.
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return nil }
        do { try data.write(to: url); return url } catch { return nil }
    }
}


// MARK: - Level

enum AudioLevel {
    /// Scale a clip so its peak sits at `target`, when its peak is between `floor` (room tone —
    /// leave it) and `target` (already loud enough). Never attenuates.
    static func normalized(_ samples: [Float], target: Float = 0.85, floor: Float = 0.02) -> [Float] {
        guard let peak = samples.map({ abs($0) }).max(), peak > floor, peak < target else { return samples }
        let gain = target / peak
        return samples.map { max(-1, min(1, $0 * gain)) }
    }
}
