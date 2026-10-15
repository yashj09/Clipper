import AVFoundation
@testable import ClipperAnalysis
import ClipperCore
import ClipperEngine
import Foundation
import Testing

/// Cold (uncached) analysis timings on real footage, per analyzer and for the whole pipeline. Wall-clock, so opt-in
/// (CLIPPER_PERF_TESTS=1) and only meaningful on an idle machine.
/// - Highlights set on `Fixtures/vod_30min.mov`: events + visual + speech + transcript.
/// - Draft set on `Fixtures/user/IMG_4148.MOV`: speech + transcript + faces.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CLIPPER_PERF_TESTS"] == "1"), .serialized)
struct IngestPerfTests {
    static func fixture(_ name: String) -> URL? {
        guard let u = FixtureLocator.directory?.appendingPathComponent(name), FileManager.default.fileExists(atPath: u.path) else { return nil }
        return u
    }

    static func time<T>(_ label: String, _ body: () async throws -> T) async rethrows -> T {
        let clock = ContinuousClock(), start = clock.now
        let value = try await body()
        print(String(format: "  %-28@ %7.2f s", label as NSString, (clock.now - start).seconds))
        return value
    }

    /// Decode-only baselines: every audio sample at the native rate, every video frame as 8-bit 4:2:0.
    static func decodeOnly(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        try await time("decode audio (native)") {
            let reader = try AVAssetReader(asset: asset)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
            reader.add(out)
            reader.startReading()
            while out.copyNextSampleBuffer() != nil {}
        }
        try await time("decode video (all frames)") {
            let reader = try AVAssetReader(asset: asset)
            let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
            out.alwaysCopiesSampleData = false
            reader.add(out)
            reader.startReading()
            var n = 0
            while out.copyNextSampleBuffer() != nil { n += 1 }
            print("    \(n) frames")
        }
    }

    func perAnalyzer(_ url: URL, kinds: Set<AnalysisKind>) async throws {
        let asset = try await MediaProbe.makeAsset(url)
        let info = asset.info
        print("\(url.lastPathComponent): \(Int(info.duration.seconds)) s, \(info.naturalWidth)×\(info.naturalHeight) @ \(info.frameRate), audio \(info.audioChannels) ch \(Int(info.audioSampleRate)) Hz")
        try await Self.decodeOnly(url)
        if kinds.contains(.speech) {
            _ = try await Self.time("speech (16 kHz envelope)") { try await AnalysisPipeline.speechActivity(url: url, duration: info.duration.seconds) }
        }
        if kinds.contains(.loudness) {
            _ = try await Self.time("loudness") { try await AudioFileLoudness.measure(url: url) }
        }
        if kinds.contains(.events) {
            _ = try await Self.time("events (SoundAnalysis)") { try await SoundEventAnalyzer().analyze(url: url) }
        }
        if kinds.contains(.visual) {
            _ = try await Self.time("visual (image generator)") { try await VisualActivityAnalyzer().analyze(url: url, info: info) }
        }
        if kinds.contains(.faces) {
            _ = try await Self.time("faces (Vision, 4/s)") { try await FaceAnalyzer().analyze(url: url, info: info, range: nil, progress: nil) }
        }
        if kinds.contains(.transcript) {
            _ = try await Self.time("transcript (SpeechAnalyzer)") { try await AppleTranscriber().transcribe(url: url, locale: Locale(identifier: "en-US")) }
        }
        var request = AudioIngest.Request()
        request.speech = kinds.contains(.speech)
        request.events = kinds.contains(.events) ? SoundEventAnalyzer() : nil
        request.transcriber = kinds.contains(.transcript) ? AppleTranscriber() : nil
        _ = await Self.time("shared audio ingest") { await AudioIngest.run(url: url, duration: info.duration.seconds, request: request) }
        _ = try await Self.time("pipeline, all kinds, cold") {
            try await AnalysisPipeline(cache: nil).analyze(asset, kinds: kinds)
        }
    }

    /// Building blocks of a shared audio ingest on the VOD: resampling, single-stream SoundAnalysis, faces.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLIPPER_PERF_PROBE"] == "1" && fixture("vod_30min.mov") != nil))
    func probeComponents() async throws {
        let url = Self.fixture("vod_30min.mov")!
        let info = try await MediaProbe.probe(url)
        let mono = try await Self.time("readMono native") { try await AudioReader.readMono(url: url, sampleRate: info.audioSampleRate) }
        _ = await Self.time("Resampler → 16 kHz") { Resampler.resample(mono, from: info.audioSampleRate, to: 16_000) }
        var single = SoundEventAnalyzer()
        single.chunkDuration = 1e9
        _ = try await Self.time("events, one stream") { try await single.analyze(url: url) }
        _ = try await Self.time("faces (Vision, 4/s)") { try await FaceAnalyzer().analyze(url: url, info: info, range: nil, progress: nil) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLIPPER_PERF_PROBE"] == "1"))
    func probeGeneratorChoices() async throws {
        for name in ["bg_1080x1920_60.mov", "user/IMG_4148.MOV", "vod_30min.mov", "overlay_1280x720_30.mov", "hdr_hlg_10bit.mov"] {
            guard let url = Self.fixture(name) else { continue }
            let asset = AVURLAsset(url: url)
            let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
            // Sync samples via a passthrough read (no decode).
            let reader = try AVAssetReader(asset: asset)
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 30, preferredTimescale: 600))
            reader.add(out)
            reader.startReading()
            var sync: [Double] = [], all: [Double] = []
            while let sb = out.copyNextSampleBuffer() {
                let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                all.append(t)
                let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
                if (att?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) != true { sync.append(t) }
            }
            let g = VisualActivityAnalyzer.makeGenerator(asset: asset, maximumSize: 256, tolerance: 0.5)
            var picks: [String] = []
            for await r in g.images(for: (0..<min(20, Int(all.last ?? 0))).map { CMTime(seconds: Double($0), preferredTimescale: 600) }) {
                if case .success(let req, let image, let actual) = r {
                    picks.append(String(format: "%.3f→%.4f(%dx%d)", req.seconds, actual.seconds, image.width, image.height))
                }
            }
            print("\(name): sync \(sync.prefix(12).map { String(format: "%.3f", $0) }) frames \(all.count) in 30 s\n  picks \(picks)")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLIPPER_PERF_PROBE"] == "1"))
    func probeDownmix() async throws {
        for (channels, layout) in [(2, kAudioChannelLayoutTag_Stereo), (6, kAudioChannelLayoutTag_MPEG_5_1_A)] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("downmix-\(channels).caf")
            var acl = AudioChannelLayout(); acl.mChannelLayoutTag = layout
            let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: AVAudioChannelLayout(layout: &acl))
            let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 48_000)!
            buf.frameLength = 48_000
            for c in 0..<channels { for i in 0..<48_000 { buf.floatChannelData![c][i] = c == 0 ? 0 : 0 } }
            // One channel at a time carries 0.1, the rest silence: the mono output reveals each coefficient.
            var coefficients: [Float] = []
            for probe in 0..<channels {
                for c in 0..<channels { for i in 0..<48_000 { buf.floatChannelData![c][i] = c == probe ? 0.1 * Float(sin(Double(i) * 0.05)) : 0 } }
                let u = url.deletingPathExtension().appendingPathExtension("\(probe).caf")
                let f = try AVAudioFile(forWriting: u, settings: fmt.settings)
                try f.write(from: buf)
                _ = f
                let mono = try await AudioReader.readMono(url: u, sampleRate: 48_000)
                let k = (1000..<2000).map { mono[$0] / (0.1 * Float(sin(Double($0) * 0.05))) }.sorted()[500]
                coefficients.append(k)
            }
            _ = file
            print("downmix \(channels) ch → mono coefficients: \(coefficients)")
        }
    }

    @Test(.enabled(if: fixture("vod_30min.mov") != nil)) func highlightsSetOnVOD() async throws {
        try await perAnalyzer(Self.fixture("vod_30min.mov")!, kinds: [.events, .visual, .speech, .transcript])
    }

    @Test(.enabled(if: fixture("user/IMG_4148.MOV") != nil)) func draftSetOnPhoneClip() async throws {
        try await perAnalyzer(Self.fixture("user/IMG_4148.MOV")!, kinds: [.speech, .transcript, .faces])
    }
}
