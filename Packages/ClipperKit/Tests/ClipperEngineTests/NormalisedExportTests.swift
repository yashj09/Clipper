import AVFoundation
import ClipperCore
import Foundation
import Testing
@testable import ClipperEngine

/// A normalised export decodes and mixes the timeline's audio once (measuring pass → temporary CAF → render pass).
@Suite(.serialized) struct NormalisedExportTests {
    static func dir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("clipper-normalised-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Stereo multi-tone (different partials per channel and seed, up to ~5 kHz) as a 32-bit float WAV at 48 kHz.
    /// Tonal and band-limited so AAC keeps it nearly intact, yet a one-sample shift costs > 20 dB of SNR.
    static func toneWAV(_ url: URL, seconds: Double, amplitude: Float, seed: Double) throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * 48_000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for c in 0..<2 {
            let partials = [223.0, 1371, 3109, 4877].map { $0 * (1 + 0.07 * seed + 0.03 * Double(c)) }
            for i in 0..<Int(frames) {
                let t = Double(i) / 48_000
                buffer.floatChannelData![c][i] = amplitude * Float(partials.enumerated().map { k, f in
                    sin(2 * .pi * f * t + Double(k) * seed) / 4
                }.reduce(0, +))
            }
        }
        try file.write(from: buffer)
    }

    /// Decoded audio of an exported file: interleaved 48 kHz stereo Float32.
    static func decode(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: Exporter.pcmSettings)
        reader.add(out)
        reader.startReading()
        var all: [Float] = []
        while let sb = out.copyNextSampleBuffer() { all += AudioSampleBuffers.floats(sb) }
        return all
    }

    /// Two overlapping tone clips on two audio tracks, a gap of silence, then the first clip again: 6 s, ≈ −30 LUFS.
    static func timeline(in dir: URL) async throws -> (Timeline, [AssetID: MediaAsset]) {
        let a = dir.appendingPathComponent("a.wav"), b = dir.appendingPathComponent("b.wav")
        try toneWAV(a, seconds: 4, amplitude: 0.08, seed: 1)
        try toneWAV(b, seconds: 4, amplitude: 0.03, seed: 2)
        let assetA = try await MediaProbe.makeAsset(a), assetB = try await MediaProbe.makeAsset(b)
        func clip(_ asset: MediaAsset, _ start: Double, _ end: Double) -> Item {
            Item(range: TimeRange(seconds: start, end), content: .media(MediaRef(asset: asset.id, source: TimeRange(seconds: 0, end - start))))
        }
        let tl = Timeline(name: "noise", canvas: Canvas(width: 320, height: 568), tracks: [
            Track(kind: .audio, items: [clip(assetA, 0, 4), clip(assetA, 5, 6)]),
            Track(kind: .music, items: [clip(assetB, 1, 3)]),
        ])
        return (tl, [assetA.id: assetA, assetB.id: assetB])
    }

    static func leftovers(_ dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("partial") }
    }

    @Test func audioMatchesTheMixSampleForSampleAndHitsTheTarget() async throws {
        let dir = try Self.dir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (tl, assets) = try await Self.timeline(in: dir)
        var preset = try #require(ExportPreset.named("master-hevc"))
        preset.sidecars = []
        preset.audioBitrate = 320_000
        let plainURL = dir.appendingPathComponent("plain.mov")
        _ = try await Exporter.export(tl, assets: assets, preset: preset, to: plainURL)   // single pass (no target)
        preset.loudness = -14
        let url = dir.appendingPathComponent("normalised.mov")
        let result = try await Exporter.export(tl, assets: assets, preset: preset, to: url)
        let gain = try #require(result.appliedGain)

        let plain = try await Self.decode(plainURL), normalised = try await Self.decode(url)
        // Sample-accurate: both carry exactly the timeline's 6 s of audio.
        #expect(normalised.count == 6 * 48_000 * 2)
        #expect(normalised.count == plain.count)
        // In sync with the single-pass mix: it matches gain × single pass best at lag 0, and far better than ±1 sample.
        let g = Float(pow(10, gain / 20))
        func snr(lag: Int) -> Double {
            var signal = 0.0, noise = 0.0
            for i in 4..<(min(plain.count, normalised.count) - 4) {
                let ref = Double(plain[i] * g), d = Double(normalised[i + lag * 2]) - ref
                signal += ref * ref
                noise += d * d
            }
            return 10 * log10(signal / max(noise, 1e-20))
        }
        let aligned = snr(lag: 0), early = snr(lag: -1), late = snr(lag: 1)
        #expect(aligned > 30 && aligned > max(early, late) + 10, "SNR at lag 0: \(aligned) dB, ±1: \(early) / \(late) dB")
        let loudness = try await AudioFileLoudness.measure(url: url)
        print("normalised export: gain \(gain) dB, \(loudness.integrated) LUFS, TP \(loudness.truePeak), SNR vs single pass \(aligned) dB (±1 sample: \(early) / \(late) dB)")
        #expect(abs(loudness.integrated - -14) <= 0.1)
        #expect(try Self.leftovers(dir).isEmpty)
    }

    @Test func cancelledExportLeavesNoTemporaryFiles() async throws {
        let dir = try Self.dir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (tl, assets) = try await Self.timeline(in: dir)
        var preset = try #require(ExportPreset.named("master-hevc"))
        preset.sidecars = []
        preset.loudness = -14
        let url = dir.appendingPathComponent("cancelled.mov")
        let normalised = preset
        var cancelled = 0
        for delay in [0, 5, 40, 150, 400] {   // during the build, the measuring pass and the render
            let task = Task { try await Exporter.export(tl, assets: assets, preset: normalised, to: url) }
            try await Task.sleep(for: .milliseconds(delay))
            task.cancel()
            do { _ = try await task.value } catch is CancellationError { cancelled += 1 }
            #expect(try Self.leftovers(dir).isEmpty, "after cancelling at \(delay) ms")
        }
        #expect(cancelled >= 3)
    }

    @Test func captureFillsGapsAndDropsOverlaps() throws {
        let dir = try Self.dir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("mix.caf")
        let writer = try MixCapture.Writer(url: url)
        let ones = [Float](repeating: 1, count: 100 * 2), twos = [Float](repeating: 2, count: 100 * 2)
        try writer.write(ones, at: CMTime(value: 0, timescale: 48_000))
        try writer.write(twos, at: CMTime(value: 150, timescale: 48_000))   // 50-frame gap → silence
        try writer.write(ones, at: CMTime(value: 200, timescale: 48_000))   // overlaps by 50 frames → head dropped
        writer.close()
        let reader = try MixCapture.Reader(url: url)
        var samples: [Float] = []
        var first: CMTime?
        while let sb = reader.copyNextSampleBuffer() {
            first = first ?? CMSampleBufferGetPresentationTimeStamp(sb)
            samples += AudioSampleBuffers.floats(sb)
        }
        #expect(first == .zero)
        let left = stride(from: 0, to: samples.count, by: 2).map { samples[$0] }
        #expect(left.count == 300)
        #expect(left[0..<100].allSatisfy { $0 == 1 } && left[100..<150].allSatisfy { $0 == 0 })
        #expect(left[150..<250].allSatisfy { $0 == 2 } && left[250..<300].allSatisfy { $0 == 1 })
    }
}
