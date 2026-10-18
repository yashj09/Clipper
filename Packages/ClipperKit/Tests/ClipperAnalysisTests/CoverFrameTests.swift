@testable import ClipperAnalysis
import ClipperCore
import ClipperEngine
import Foundation
import ImageIO
import Testing

@Suite struct CoverFrameTests {
    static func sample(_ t: Double, sharpness: Double = 0.5, luma: Double = 0.45, subject: Bool = false) -> VisualSample {
        VisualSample(time: t, change: 0, salient: subject ? NormRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4) : nil,
                     sharpness: sharpness, luma: luma)
    }

    @Test func facesSharpnessAndExposureRankMoments() {
        let samples = (0...10).map { t -> VisualSample in
            switch t {
            case 3: Self.sample(3, sharpness: 0.9, luma: 0.05)   // sharp but nearly black
            case 6: Self.sample(6, sharpness: 0.6)
            case 8: Self.sample(8, sharpness: 0.9, subject: true)
            default: Self.sample(Double(t), sharpness: 0.5)
            }
        }
        let faces = FaceTrack(samples: [FaceSample(time: 6.25, rect: NormRect(x: 0.4, y: 0.2, width: 0.2, height: 0.2), confidence: 0.9)])
        let analysis = AssetAnalysis(faces: faces, visual: VisualActivity(samples: samples, sceneCuts: []))
        let picked = CoverFramePicker.candidates(analysis, count: 3, duration: 10.2)
        #expect(picked.map(\.time) == [6, 8, 1])
        #expect(picked[0].reasons.contains("face") && picked[1].reasons.contains("framed subject"))
        #expect(zip(picked, picked.dropFirst()).allSatisfy { $0.score >= $1.score })
        for (a, b) in zip(picked, picked.dropFirst()) { #expect(abs(a.time - b.time) >= 2) }
        #expect(!picked.contains { $0.time == 3 })
    }

    @Test func clipEndsAreSkipped() {
        let samples = [Self.sample(0, sharpness: 1), Self.sample(1), Self.sample(4), Self.sample(5.8, sharpness: 1)]
        let analysis = AssetAnalysis(visual: VisualActivity(samples: samples, sceneCuts: []))
        #expect(CoverFramePicker.candidates(analysis, count: 4, duration: 6).map(\.time) == [1, 4])
        let still = AssetAnalysis(visual: VisualActivity(samples: [Self.sample(0)], sceneCuts: []))
        #expect(CoverFramePicker.candidates(still, count: 1, duration: 0).map(\.time) == [0])
    }

    /// The test pattern has no face: refine keeps the ranking and the scores; export writes the exact frame size.
    @Test(.enabled(if: FixtureLocator.directory.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("bg_1080x1920_60.mov").path) } ?? false,
                   "Fixtures/bg_1080x1920_60.mov not present"))
    func refineAndExportOnTheFixture() async throws {
        let url = try #require(FixtureLocator.directory).appendingPathComponent("bg_1080x1920_60.mov")
        let asset = try await MediaProbe.makeAsset(url)
        let analysis = try await AnalysisPipeline(cache: nil).analyze(asset, kinds: [.visual, .faces])
        let rough = CoverFramePicker.candidates(analysis, count: 4, duration: asset.info.duration.seconds)
        #expect(rough.count == 4)
        let refined = try await CoverFramePicker.refine(url: url, candidates: rough)
        #expect(refined == rough)

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("clipper-cover-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: out) }
        try await CoverFramePicker.export(url: url, time: refined[0].time, to: out, maxWidth: 540)
        let source = try #require(CGImageSourceCreateWithURL(out as CFURL, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 540 && props[kCGImagePropertyPixelHeight] as? Int == 960)
    }
}
