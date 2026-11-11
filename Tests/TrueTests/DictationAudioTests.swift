import Testing
import Foundation
@preconcurrency import AVFoundation
@testable import True

@Suite struct DictationAudioTests {
    @Test func zeroHzAndZeroChannelRefused() {
        // AVAudioFormat can't be built with 0 Hz / 0 ch directly (it returns nil), so a refusal
        // test goes through the real validator with the formats AVFAudio will construct.
        let ok = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        #expect(AudioSafety.safeTapFormat(ok) != nil)
        // The hardware-not-ready shape: a format with sampleRate 0 (built via a stream description).
        var asbd = AudioStreamBasicDescription(mSampleRate: 0, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
            mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        let zeroHz = AVAudioFormat(streamDescription: &asbd)
        #expect(zeroHz.flatMap { AudioSafety.safeTapFormat($0) } == nil)
        asbd.mSampleRate = 48_000; asbd.mChannelsPerFrame = 0
        let zeroCh = AVAudioFormat(streamDescription: &asbd)
        #expect(zeroCh.flatMap { AudioSafety.safeTapFormat($0) } == nil)
    }

    @Test func resample48kSineTo16k() {
        let n = 48_000
        let sine = (0..<n).map { Float(sin(2 * Double.pi * 440 * Double($0) / 48_000)) * 0.5 }
        let out = AudioResampler.to16kMono(sine, sourceRate: 48_000)
        #expect(abs(out.count - 16_000) <= 1)
    }

    @Test func wavIs0600PCM16() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dict-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try #require(WavWriter.write([0, 0.5, -0.5, 1], sampleRate: 16_000, dir: dir))
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let d = try Data(contentsOf: url)
        #expect(d.count == 44 + 8)
        #expect(String(data: d.prefix(4), encoding: .ascii) == "RIFF")
    }

    @Test func sweepRemovesStaleClips() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dict-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try #require(WavWriter.write([0.1], sampleRate: 16_000, dir: dir))
        DictationFiles.sweep(dir)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }
}
