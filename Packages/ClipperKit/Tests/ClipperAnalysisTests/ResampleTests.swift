import Foundation
import Testing
@testable import ClipperAnalysis

/// Decoding 48 kHz audio at 16 kHz must not insert discontinuities at buffer boundaries.
@Suite struct ResampleTests {
    static let fixture = URL(fileURLWithPath: "/Users/yashjain/dev/Personal Projects/Clipper/Fixtures/bg_1080x1920_60.mov")

    /// Largest second difference relative to what a clean sine of this amplitude/frequency allows.
    static func clickRatio(_ x: [Float], sampleRate: Double, frequency: Double) -> Double {
        let core = x.dropFirst(2000).dropLast(2000)   // ignore codec priming/edges
        let peak = Double(core.map { abs($0) }.max() ?? 0)
        let w = 2 * Double.pi * frequency / sampleRate
        let allowed = peak * w * w
        var worst = 0.0
        let a = Array(core)
        for i in 2..<a.count { worst = max(worst, Double(abs(a[i] - 2 * a[i - 1] + a[i - 2]))) }
        return worst / max(allowed, 1e-9)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: fixture.path)), arguments: [16_000.0, 22_050.0, 48_000.0])
    func noClicksWhenResampling(rate: Double) async throws {
        let x = try await AudioReader.readMono(url: Self.fixture, sampleRate: rate)
        #expect(abs(Double(x.count) / rate - 10) < 0.1)
        let ratio = Self.clickRatio(x, sampleRate: rate, frequency: 1000)
        print("rate \(rate): click ratio \(ratio)")
        #expect(ratio < 1.5, "discontinuities at \(rate) Hz (ratio \(ratio))")
    }
}

import ClipperCore
import ClipperEngine

/// The export mix resamples sources to 48 kHz (e.g. 44.1 kHz music). The delivered audio must be click-free.
@Suite struct ExportResampleTests {
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg")))
    func exportedAudioFrom44kSourceHasNoClicks() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clipper-resample-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("tone44k.m4a")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        p.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "sine=f=1000:sample_rate=44100:d=8",
                       "-c:a", "alac", src.path]   // lossless, so any artefact comes from our pipeline
        try p.run(); p.waitUntilExit()
        let asset = try await MediaProbe.makeAsset(src)
        var title = Item(range: TimeRange(seconds: 0, 8), content: .solid(.black))
        title.name = "bg"
        let tl = Timeline(name: "t", canvas: Canvas(width: 320, height: 240), tracks: [
            Track(kind: .video, items: [title]),
            Track(kind: .music, items: [Item(range: TimeRange(seconds: 0, 8), content: .media(MediaRef(asset: asset.id, source: TimeRange(seconds: 0, 8))))]),
        ])
        var preset = ExportPreset.named("master-prores422hq")!
        preset.sidecars = []
        let out = dir.appendingPathComponent("out.mov")
        _ = try await Exporter.export(tl, assets: [asset.id: asset], preset: preset, to: out)
        let x = try await AudioReader.readMono(url: out, sampleRate: 48_000)
        let ratio = ResampleTests.clickRatio(x, sampleRate: 48_000, frequency: 1000)
        print("export 44.1k→48k click ratio \(ratio)")
        #expect(ratio < 1.5)
    }
}
