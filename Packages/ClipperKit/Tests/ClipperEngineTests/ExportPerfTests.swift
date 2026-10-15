import AVFoundation
import ClipperCore
import Foundation
import Testing
@testable import ClipperEngine

/// Wall-clock export benchmarks on real footage: only meaningful on an idle machine, so opt-in (CLIPPER_PERF_TESTS=1).
/// `CLIPPER_PERF_MINUTES` sets the timeline length (default 5) cut from `Fixtures/vod_30min.mov`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CLIPPER_PERF_TESTS"] == "1" && Fixture.url("vod_30min.mov") != nil),
       .serialized)
struct ExportPerfTests {
    static var minutes: Double { Double(ProcessInfo.processInfo.environment["CLIPPER_PERF_MINUTES"] ?? "") ?? 5 }

    /// The VOD cut into 20 s pieces (every other piece), like a highlights edit: many audio edits to mix.
    func timeline() async throws -> (Timeline, [AssetID: MediaAsset]) {
        let vod = try await MediaProbe.makeAsset(Fixture.url("vod_30min.mov")!)
        var items: [Item] = []
        var t = 0.0
        let piece = 20.0
        while t < Self.minutes * 60 - 1e-9 {
            let src = (t * 2).truncatingRemainder(dividingBy: 1700)
            items.append(Item(range: TimeRange(seconds: t, t + piece),
                              content: .media(MediaRef(asset: vod.id, source: TimeRange(seconds: src, src + piece)))))
            t += piece
        }
        let tl = Timeline(name: "perf", canvas: Canvas(width: 1920, height: 1080, frameRate: .fps60),
                          tracks: [Track(kind: .video, items: items)])
        return (tl, [vod.id: vod])
    }

    @Test func normalisedExport() async throws {
        let (tl, assets) = try await timeline()
        let preset = try #require(ExportPreset.named("youtube-1080p"))
        let url = Fixture.out("perf-normalised.mp4")
        let clock = ContinuousClock()
        let measure = try await clock.measure { _ = try await Exporter.measureMix(tl, assets: assets) }
        var result: ExportResult?
        let total = try await clock.measure { result = try await Exporter.export(tl, assets: assets, preset: preset, to: url) }
        var plain = preset; plain.loudness = nil
        let unnormalised = try await clock.measure {
            _ = try await Exporter.export(tl, assets: assets, preset: plain, to: Fixture.out("perf-plain.mp4"))
        }
        let r = try #require(result)
        print(String(format: "export perf (%.0f min @ 1080p60): measureMix alone %.2fs; normalised export %.2fs (%d frames, gain %+.2f dB); "
                     + "export without loudness target %.2fs", Self.minutes, measure.seconds, total.seconds, r.frames,
                     r.appliedGain ?? 0, unnormalised.seconds))
    }
}
