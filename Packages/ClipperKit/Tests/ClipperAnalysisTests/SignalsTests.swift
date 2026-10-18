import AVFoundation
@testable import ClipperAnalysis
import ClipperCore
import ClipperEngine
import CoreGraphics
import Foundation
import Synchronization
import Testing

// Highlight signals for long recordings: SoundAnalysis events and sampled visual activity.

// MARK: - Helpers

private enum SignalMedia {
    static func fixture(_ name: String) -> URL? {
        guard let d = FixtureLocator.directory else { return nil }
        let u = d.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    static func has(_ names: String...) -> Bool { names.allSatisfy { fixture($0) != nil } }

    static func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("clipper-signals-\(UUID().uuidString).\(ext)")
    }

    static func writeWAV(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
    }

    /// `first` followed by `second` (video only) in one H.264 file; returns the join time in seconds.
    static func concatenate(_ first: URL, _ second: URL, to out: URL) async throws -> Double {
        let comp = AVMutableComposition()
        let track = try #require(comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        var t = CMTime.zero
        for url in [first, second] {
            let asset = AVURLAsset(url: url)
            let source = try #require(try await asset.loadTracks(withMediaType: .video).first)
            let range = try await source.load(.timeRange)
            try track.insertTimeRange(range, of: source, at: t)
            t = t + range.duration
        }
        let join = try await AVURLAsset(url: first).loadTracks(withMediaType: .video).first!.load(.timeRange).duration.seconds
        let video = try await AVVideoComposition.videoComposition(withPropertiesOf: comp)
        let session = try #require(AVAssetExportSession(asset: comp, presetName: AVAssetExportPreset1280x720))
        session.videoComposition = video
        try await session.export(to: out, as: .mov)
        return join
    }

    /// Muxes `audio` under the video of `video` (looped to the audio length), passthrough.
    static func mux(video: URL, audio: URL, to out: URL) async throws {
        let comp = AVMutableComposition()
        let va = AVURLAsset(url: video), aa = AVURLAsset(url: audio)
        let vTrack = try #require(try await va.loadTracks(withMediaType: .video).first)
        let aTrack = try #require(try await aa.loadTracks(withMediaType: .audio).first)
        let vDur = try await va.load(.duration), aDur = try await aa.load(.duration)
        let cv = try #require(comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        let ca = try #require(comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        var t = CMTime.zero
        while t < aDur {
            let d = CMTimeMinimum(vDur, aDur - t)
            try cv.insertTimeRange(CMTimeRange(start: .zero, duration: d), of: vTrack, at: t)
            t = t + d
        }
        try ca.insertTimeRange(CMTimeRange(start: .zero, duration: aDur), of: aTrack, at: .zero)
        let session = try #require(AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough))
        try await session.export(to: out, as: .mov)
    }

    static func inUnitSquare(_ r: NormRect) -> Bool {
        r.x >= 0 && r.y >= 0 && r.width > 0 && r.height > 0 && r.x + r.width <= 1 + 1e-9 && r.y + r.height <= 1 + 1e-9
    }
}

private func elapsedSeconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }

private struct SentenceTruth: Decodable {
    struct Sentence: Decodable { var text: String; var start: Double; var end: Double }
    var duration: Double
    var sentences: [Sentence]
}

private final class CountingCache: AnalysisCache {
    let inner: DirectoryAnalysisCache
    let hits = Mutex(0), stores = Mutex(0)
    init(directory: URL) { inner = DirectoryAnalysisCache(directory: directory) }
    func load(key: AssetKey, analyzer: String, version: Int) async -> Data? {
        let d = await inner.load(key: key, analyzer: analyzer, version: version)
        if d != nil { hits.withLock { $0 += 1 } }
        return d
    }
    func store(_ data: Data, key: AssetKey, analyzer: String, version: Int) async throws {
        stores.withLock { $0 += 1 }
        try await inner.store(data, key: key, analyzer: analyzer, version: version)
    }
}

// MARK: - Sound events

@Suite struct SoundEventTests {
    @Test func defaultLabelsAreClassifierIdentifiers() throws {
        let known = Set(try SoundEventAnalyzer.knownLabels())
        #expect(known.count > 300)
        #expect(SoundEventAnalyzer.defaultLabels.isSubset(of: known))
        #expect(SoundEventAnalyzer.category(of: "belly_laugh") == "laughter")
        #expect(SoundEventAnalyzer.category(of: "clapping") == "applause")
        #expect(SoundEventAnalyzer.category(of: "yell") == "shouting")
        #expect(SoundEventAnalyzer.category(of: "booing") == "booing")
    }

    @Test func unknownLabelsThrow() async throws {
        let url = SignalMedia.tempURL("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try SignalMedia.writeWAV([Float](repeating: 0, count: 16_000), sampleRate: 16_000, to: url)
        await #expect(throws: SoundEventError.self) {
            _ = try await SoundEventAnalyzer(labels: ["laughter", "giggle_snort"]).analyze(url: url)
        }
    }

    @Test func mergeJoinsSameLabelWindows() {
        typealias W = SoundEventAnalyzer.Window
        let windows = [
            W(start: 0.0, end: 1.5, scores: ["laughter": 0.6]),
            W(start: 0.75, end: 2.25, scores: ["laughter": 0.9, "applause": 0.55]),   // overlaps → same event
            W(start: 1.5, end: 3.0, scores: ["laughter": 0.4]),                       // below threshold
            W(start: 2.75, end: 4.25, scores: ["laughter": 0.7]),                     // gap 0.5 ≤ 0.6 → merges
            W(start: 5.0, end: 6.5, scores: ["laughter": 0.8, "applause": 0.95]),     // gap 0.75 → new event
        ]
        let events = SoundEventAnalyzer.merge(windows.shuffled(), minConfidence: 0.5, maxGap: 0.6)
        #expect(events == [
            SoundEvent(label: "laughter", start: 0, end: 4.25, confidence: 0.9),
            SoundEvent(label: "applause", start: 0.75, end: 2.25, confidence: 0.55),
            SoundEvent(label: "applause", start: 5.0, end: 6.5, confidence: 0.95),
            SoundEvent(label: "laughter", start: 5.0, end: 6.5, confidence: 0.8),
        ])
    }

    @Test func silenceHasNoEvents() async throws {
        let sr = 16_000.0
        let url = SignalMedia.tempURL("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try SignalMedia.writeWAV(Signal.noise(count: Int(20 * sr), rmsDB: -75, seed: 3), sampleRate: sr, to: url)
        let progress = Mutex(0.0)
        let events = try await SoundEventAnalyzer().analyze(url: url) { p in progress.withLock { $0 = max($0, p) } }
        #expect(events.events.isEmpty)
        #expect(progress.withLock { $0 } == 1)
    }

    /// Speech, 6 s of digital silence, speech → two separate `speech` events with the gap between them.
    @Test(.enabled(if: SignalMedia.has("speech_clean.wav", "speech_truth.json"), "fixtures not present"))
    func gapSplitsEvents() async throws {
        let wav = try #require(SignalMedia.fixture("speech_clean.wav"))
        let truth = try JSONDecoder().decode(SentenceTruth.self, from: Data(contentsOf: try #require(SignalMedia.fixture("speech_truth.json"))))
        let sr = 16_000.0   // the fixture's native rate, so AudioReader doesn't resample
        let all = try await AudioReader.readMono(url: wav, sampleRate: sr)
        func cut(_ s: SentenceTruth.Sentence) -> ArraySlice<Float> { all[Int(s.start * sr)..<min(all.count, Int(s.end * sr))] }
        let first = cut(truth.sentences[0]), second = cut(truth.sentences[2])
        let gapStart = Double(first.count) / sr, gapEnd = gapStart + 6
        let url = SignalMedia.tempURL("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try SignalMedia.writeWAV(Array(first) + [Float](repeating: 0, count: Int(6 * sr)) + Array(second), sampleRate: sr, to: url)

        let events = try await SoundEventAnalyzer(labels: ["speech"]).analyze(url: url).events
        print(String(format: "speech | 6 s gap (%.2f–%.2f) | speech: ", gapStart, gapEnd)
              + "\(events.map { String(format: "%.2f–%.2f (%.2f)", $0.start, $0.end, $0.confidence) })")
        #expect(events.count == 2)
        #expect(events.first.map { $0.start < 0.5 && $0.end > gapStart - 0.8 && $0.end < gapStart + 1.6 } == true)
        #expect(events.last.map { $0.start > gapEnd - 1.6 && $0.start < gapEnd + 0.8 } == true)
    }

    /// Positive path through real media: the classifier's `speech` label on the TTS fixture, as WAV and inside a
    /// video container, full and ranged (times stay in source seconds).
    @Test(.enabled(if: SignalMedia.has("speech_clean.wav", "speech_truth.json", "overlay_1280x720_30.mov"), "fixtures not present"))
    func speechLabelTracksSentences() async throws {
        let wav = try #require(SignalMedia.fixture("speech_clean.wav"))
        let truth = try JSONDecoder().decode(SentenceTruth.self, from: Data(contentsOf: try #require(SignalMedia.fixture("speech_truth.json"))))
        let analyzer = SoundEventAnalyzer(labels: ["speech"])
        let fromWav = try await analyzer.analyze(url: wav).events
        print("speech events (wav): \(fromWav.map { String(format: "%.2f–%.2f", $0.start, $0.end) })")
        #expect(!fromWav.isEmpty)
        #expect(fromWav.allSatisfy { $0.label == "speech" && $0.start >= 0 && $0.end <= truth.duration + 0.01 && $0.confidence >= 0.5 })
        // Every sentence is covered by speech events (its pauses, ≤ 2 s, are bridged by 1.5 s windows + the merge gap).
        for s in truth.sentences {
            let covered = fromWav.reduce(0.0) { $0 + max(0, min($1.end, s.end) - max($1.start, s.start)) }
            #expect(covered >= 0.6 * (s.end - s.start), "\(s.text)")
        }

        // Same audio in a .mov with a video track.
        let mov = SignalMedia.tempURL("mov")
        defer { try? FileManager.default.removeItem(at: mov) }
        try await SignalMedia.mux(video: try #require(SignalMedia.fixture("overlay_1280x720_30.mov")), audio: wav, to: mov)
        let fromMov = try await analyzer.analyze(url: mov).events
        #expect(fromMov.count == fromWav.count)
        for (a, b) in zip(fromMov, fromWav) { #expect(abs(a.start - b.start) < 0.1 && abs(a.end - b.end) < 0.1) }

        // A range is reported in source time and agrees with the full pass where both have whole windows.
        let part = try await analyzer.analyze(url: mov, range: 10...22).events
        print("speech events (mov 10–22 s): \(part.map { String(format: "%.2f–%.2f", $0.start, $0.end) })")
        #expect(!part.isEmpty)
        #expect(part.allSatisfy { $0.start >= 9.99 && $0.end <= 22.01 })
        #expect(part.allSatisfy { p in fromMov.contains { $0.start <= p.start + 0.8 && $0.end >= p.end - 0.8 } })
    }

    /// Chunks analyzed concurrently give the same events as one pass.
    @Test(.enabled(if: SignalMedia.has("speech_clean.wav"), "Fixtures/speech_clean.wav not present"))
    func chunkedAnalysisMatchesSinglePass() async throws {
        let wav = try #require(SignalMedia.fixture("speech_clean.wav"))
        var single = SoundEventAnalyzer(labels: ["speech", "silence"])
        single.chunkDuration = 3_600
        var chunked = single
        chunked.chunkDuration = 7
        let a = try await single.analyze(url: wav).events
        let b = try await chunked.analyze(url: wav).events
        #expect(a.count == b.count)
        for (x, y) in zip(a, b) {
            #expect(x.label == y.label && abs(x.start - y.start) < 0.01 && abs(x.end - y.end) < 0.01)
            #expect(abs(x.confidence - y.confidence) < 0.05)
        }
    }

    /// Throughput on the 30-minute fixture (440 Hz tone: none of the reaction labels may fire).
    @Test(.enabled(if: SignalMedia.has("long_30min_1080p60.mov"), "Fixtures/long_30min_1080p60.mov not present"))
    func longRecordingThroughput() async throws {
        let url = try #require(SignalMedia.fixture("long_30min_1080p60.mov"))
        let duration = try await MediaProbe.probe(url).duration.seconds
        let clock = ContinuousClock(), t0 = clock.now
        let events = try await SoundEventAnalyzer().analyze(url: url)
        let elapsed = elapsedSeconds(clock.now - t0)
        print(String(format: "sound events: %.0f s of audio in %.1f s = %.0f× realtime (2 h ≈ %.0f s); %d events",
                     duration, elapsed, duration / elapsed, 7_200 * elapsed / duration, events.events.count))
        #expect(events.events.isEmpty)
        #expect(duration / elapsed > 20)   // generous: the target is ≥ 60× on an idle M4 Pro
    }
}

// MARK: - Visual activity

@Suite struct VisualActivityTests {
    @Test func changeMetricAndCutPicking() {
        let w = VisualActivityAnalyzer.Signature.width, h = VisualActivityAnalyzer.Signature.height
        let black = VisualActivityAnalyzer.Signature(rgba: [UInt8](repeating: 0, count: w * h * 4))
        let white = VisualActivityAnalyzer.Signature(rgba: [UInt8](repeating: 255, count: w * h * 4))
        #expect(VisualActivityAnalyzer.change(black, black) == 0)
        #expect(abs(VisualActivityAnalyzer.change(black, white) - 1) < 1e-9)

        // Busy footage (change ≈ 0.2 ± 0.05) with one hard cut between t = 40 and 41.
        var rng = SplitMix64(seed: 9)
        var samples = (0..<100).map { VisualSample(time: Double($0), change: Double.random(in: 0.15...0.25, using: &rng), salient: nil) }
        samples[41].change = 0.7
        samples[42].change = 0.35   // a second, smaller jump right after is not another cut
        #expect(VisualActivityAnalyzer().sceneCuts(samples) == [40.5])
        // Static footage: a moderate jump below the 0.3 floor is not a cut.
        let still = (0..<50).map { VisualSample(time: Double($0), change: $0 == 20 ? 0.25 : 0.01, salient: nil) }
        #expect(VisualActivityAnalyzer().sceneCuts(still).isEmpty)
    }

    @Test func frameMeasureReadsExposureColourAndDetail() {
        let w = 64, h = 36
        func frame(_ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> VisualActivityAnalyzer.FrameMeasure {
            var rgba = [UInt8](repeating: 255, count: w * h * 4)
            for y in 0..<h { for x in 0..<w { let (r, g, b) = pixel(x, y); let i = 4 * (y * w + x); rgba[i] = r; rgba[i + 1] = g; rgba[i + 2] = b } }
            return VisualActivityAnalyzer.FrameMeasure(rgba: rgba, width: w, height: h)
        }
        let grey = frame { _, _ in (128, 128, 128) }
        #expect(abs(grey.luma - 128 / 255) < 1e-3 && grey.p01 == grey.p99 && grey.sharpness == 0 && grey.saturation == 0)
        #expect(grey.r == grey.g && grey.g == grey.b)

        let red = frame { _, _ in (255, 0, 0) }
        #expect(red.r == 1 && red.g == 0 && red.b == 0 && red.saturation == 1 && abs(red.luma - 0.2126) < 1e-3)

        let checker = frame { x, y in (x + y) % 2 == 0 ? (0, 0, 0) : (255, 255, 255) }
        let ramp = frame { x, _ in let v = UInt8(x * 4); return (v, v, v) }
        #expect(checker.sharpness > 0.99 && ramp.sharpness < 0.05)
        #expect(checker.p01 == 0 && checker.p99 == 1)

        let stats = VisualActivityAnalyzer.FrameMeasure.median([grey, red, checker])
        #expect(stats.r == 128 / 255 && stats.saturation == 0)
    }

    @Test func samplesFromBeforeSharpnessStillDecode() throws {
        let v1 = Data(#"{"samples":[{"time":1,"change":0.2}],"sceneCuts":[]}"#.utf8)
        let activity = try CacheCodec.decoder.decode(VisualActivity.self, from: v1)
        #expect(activity.samples == [VisualSample(time: 1, change: 0.2, salient: nil)])
        #expect(activity.samples[0].sharpness == nil && activity.samples[0].luma == nil)
    }

    @Test func unionOfSalientObjects() throws {
        // Vision rects have a lower-left origin; the union is returned top-left.
        let r = try #require(VisualActivityAnalyzer.union([CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.2),
                                                           CGRect(x: 0.5, y: 0.6, width: 0.3, height: 0.3)]))
        #expect(abs(r.x - 0.1) < 1e-9 && abs(r.y - 0.1) < 1e-9 && abs(r.width - 0.7) < 1e-9 && abs(r.height - 0.4) < 1e-9)
        #expect(VisualActivityAnalyzer.union([]) == nil)
    }

    /// Still image: one sample at t = 0; saliency finds the lone bright square (top-right in display space).
    @Test func stillImageGivesOneSample() async throws {
        let w = 400, h = 300
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(gray: 0.2, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(red: 1, green: 0.9, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 280, y: 190, width: 80, height: 80))   // CG origin is bottom-left → top-right square
        let image = try #require(ctx.makeImage())
        let url = SignalMedia.tempURL("png")
        defer { try? FileManager.default.removeItem(at: url) }
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))

        let info = MediaInfo(kind: .image, duration: .zero, naturalWidth: w, naturalHeight: h)
        let activity = try await VisualActivityAnalyzer().analyze(url: url, info: info).activity
        #expect(activity.samples.count == 1 && activity.samples[0].time == 0 && activity.sceneCuts.isEmpty)
        let r = try #require(activity.samples[0].salient)
        print("still image salient: \(r)")
        #expect(SignalMedia.inUnitSquare(r) && r.x + r.width / 2 > 0.5 && r.y + r.height / 2 < 0.5)
    }

    @Test(.enabled(if: SignalMedia.has("bg_1080x1920_60.mov", "overlay_1280x720_30.mov"), "fixtures not present"))
    func sceneCutAtJoin() async throws {
        let out = SignalMedia.tempURL("mov")
        defer { try? FileManager.default.removeItem(at: out) }
        let join = try await SignalMedia.concatenate(try #require(SignalMedia.fixture("bg_1080x1920_60.mov")),
                                                     try #require(SignalMedia.fixture("overlay_1280x720_30.mov")), to: out)
        let info = try await MediaProbe.probe(out)
        let progress = Mutex(0.0)
        let activity = try await VisualActivityAnalyzer().analyze(url: out, info: info) { p in progress.withLock { $0 = max($0, p) } }.activity
        print(String(format: "concat (join %.2f s): cuts %@; changes %@", join, activity.sceneCuts.map { String(format: "%.2f", $0) },
                     activity.samples.map { String(format: "%.2f", $0.change) }.joined(separator: " ")))
        #expect(activity.samples.count >= 18)
        #expect(activity.sceneCuts.contains { abs($0 - join) <= 1 })
        #expect(activity.sceneCuts.count <= 2)
        #expect(zip(activity.samples, activity.samples.dropFirst()).allSatisfy { $0.time < $1.time })
        #expect(activity.samples.allSatisfy { $0.change >= 0 && $0.change <= 1 && ($0.salient.map(SignalMedia.inUnitSquare) ?? true) })
        #expect(progress.withLock { $0 } == 1)
    }

    /// rotated_marker.mov stores a red marker in the natural top-left and is tagged rotate-90°-clockwise:
    /// sampled images must be upright (portrait, marker top-right) and saliency must point there.
    @Test(.enabled(if: SignalMedia.has("rotated_marker.mov"), "Fixtures/rotated_marker.mov not present"))
    func samplesAreDisplayOriented() async throws {
        let url = try #require(SignalMedia.fixture("rotated_marker.mov"))
        let info = try await MediaProbe.probe(url)
        let generator = VisualActivityAnalyzer.makeGenerator(asset: AVURLAsset(url: url), maximumSize: 256, tolerance: 0.5)
        let image = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        let w = image.width, h = image.height
        #expect(w < h && max(w, h) <= 256)
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        rgba.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        func isRed(_ x: Int, _ y: Int) -> Bool {   // row 0 = top of the displayed image
            let i = (y * w + x) * 4
            return rgba[i] > 150 && rgba[i + 1] < 100 && rgba[i + 2] < 100
        }
        let m = 4
        #expect(isRed(w - m, m) && !isRed(m, m) && !isRed(m, h - m) && !isRed(w - m, h - m))

        let activity = try await VisualActivityAnalyzer().analyze(url: url, info: info).activity
        print("rotated_marker salient: \(activity.samples.map { $0.salient.map { String(format: "(%.2f, %.2f, %.2f×%.2f)", $0.x, $0.y, $0.width, $0.height) } ?? "nil" })")
        #expect(activity.samples.count == 3)
        #expect(activity.samples.allSatisfy { ($0.sharpness ?? -1) >= 0 && ($0.sharpness ?? 2) <= 1 && ($0.luma ?? -1) > 0 })
        #expect(activity.sceneCuts.isEmpty)
        let salient = activity.samples.compactMap(\.salient)
        #expect(!salient.isEmpty)
        #expect(salient.allSatisfy { SignalMedia.inUnitSquare($0) && $0.x + $0.width / 2 > 0.5 && $0.y + $0.height / 2 < 0.5 })
    }

    /// Timing on the 30-minute 1080p60 HEVC fixture (2 s GOP), 1 sample/s with saliency.
    @Test(.enabled(if: SignalMedia.has("long_30min_1080p60.mov"), "Fixtures/long_30min_1080p60.mov not present"))
    func longRecordingThroughput() async throws {
        let url = try #require(SignalMedia.fixture("long_30min_1080p60.mov"))
        let info = try await MediaProbe.probe(url)
        let duration = info.duration.seconds
        let clock = ContinuousClock(), t0 = clock.now
        let activity = try await VisualActivityAnalyzer().analyze(url: url, info: info).activity
        let elapsed = elapsedSeconds(clock.now - t0)
        let salient = activity.samples.filter { $0.salient != nil }.count
        print(String(format: "visual: %.0f s at 1/s → %d samples (%d salient), %d cuts in %.1f s; 2 h ≈ %.0f s",
                     duration, activity.samples.count, salient, activity.sceneCuts.count, elapsed, 7_200 * elapsed / duration))
        #expect(activity.samples.count >= Int(duration) - 2)
        #expect(zip(activity.samples, activity.samples.dropFirst()).allSatisfy { $0.time < $1.time })
        #expect(activity.samples.allSatisfy { abs($0.time - $0.time.rounded()) <= 0.5 + 1e-6 })
        #expect(activity.samples.allSatisfy { $0.change >= 0 && $0.change <= 1 && ($0.salient.map(SignalMedia.inUnitSquare) ?? true) })
        #expect(elapsed < 90)   // generous: ≈ 20 s on an M4 Pro
    }
}

// MARK: - Pipeline

@Suite struct SignalsPipelineTests {
    @Test(.enabled(if: SignalMedia.has("bg_1080x1920_60.mov"), "Fixtures/bg_1080x1920_60.mov not present"))
    func eventsAndVisualAreCached() async throws {
        let url = try #require(SignalMedia.fixture("bg_1080x1920_60.mov"))
        let asset = try await MediaProbe.makeAsset(url)
        let dir = SignalMedia.tempURL("cache")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = CountingCache(directory: dir)
        // "beep" fires on the fixture's 1 kHz tone, so the cached artifact is non-trivial.
        let options = AnalysisOptions(events: SoundEventAnalyzer(labels: SoundEventAnalyzer.defaultLabels.union(["beep"])))
        let pipeline = AnalysisPipeline(cache: cache, options: options)
        let progress = Mutex<[AnalysisKind: Double]>([:])

        let first = try await pipeline.analyze(asset, kinds: [.events, .visual]) { kind, p in progress.withLock { $0[kind] = p } }
        let events = try #require(first.events), visual = try #require(first.visual)
        print("bg pipeline: events \(events.events.map { "\($0.label) \(String(format: "%.2f–%.2f", $0.start, $0.end))" }), "
              + "\(visual.samples.count) visual samples, cuts \(visual.sceneCuts)")
        #expect(events.events.contains { $0.label == "beep" })
        #expect(visual.samples.count == 10)
        #expect(first.transcript == nil && first.faces == nil && first.speech == nil)
        #expect(progress.withLock { $0 } == [.events: 1, .visual: 1])
        #expect(cache.stores.withLock { $0 } == 2 && cache.hits.withLock { $0 } == 0)

        let second = try await pipeline.analyze(asset, kinds: [.events, .visual])
        #expect(second == first)
        #expect(cache.hits.withLock { $0 } == 2 && cache.stores.withLock { $0 } == 2)

        // A different label set is a different analyzer id → a miss.
        let other = AnalysisPipeline(cache: cache, options: AnalysisOptions(events: SoundEventAnalyzer(labels: ["beep"])))
        _ = try await other.analyze(asset, kinds: [.events])
        #expect(cache.stores.withLock { $0 } == 3)
        #expect(AnalysisPipeline.analyzerID(.events, options: options) != AnalysisPipeline.analyzerID(.events, options: AnalysisOptions()))
        #expect(AnalysisPipeline.analyzerID(.visual, options: AnalysisOptions()) == "visual.1s.t0.5.px256.cut0.3-3-30.sal")
    }

    /// Colour on its own runs a pass without saliency; asking for visual later reuses the cached colour, and both
    /// passes measure the same frames.
    @Test(.enabled(if: SignalMedia.has("bg_1080x1920_60.mov"), "Fixtures/bg_1080x1920_60.mov not present"))
    func colorSharesTheVisualPass() async throws {
        let url = try #require(SignalMedia.fixture("bg_1080x1920_60.mov"))
        let asset = try await MediaProbe.makeAsset(url)
        let dir = SignalMedia.tempURL("cache")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = CountingCache(directory: dir)
        let pipeline = AnalysisPipeline(cache: cache)

        let colorOnly = try await pipeline.analyze(asset, kinds: [.color])
        let color = try #require(colorOnly.color)
        print("bg color: \(color)")
        #expect(colorOnly.visual == nil)
        #expect(cache.stores.withLock { $0 } == 1)
        #expect(color.p01 <= color.luma && color.luma <= color.p99 && color.saturation > 0)

        let both = try await pipeline.analyze(asset, kinds: [.visual, .color])
        #expect(both.color == color)
        #expect(cache.hits.withLock { $0 } == 1 && cache.stores.withLock { $0 } == 2)
        let visual = try #require(both.visual)
        #expect(visual.samples.allSatisfy { $0.sharpness != nil && $0.luma != nil })

        let fresh = try await AnalysisPipeline(cache: nil).analyze(asset, kinds: [.visual, .color])
        #expect(fresh.color == color && fresh.visual == visual)
        #expect(AnalysisPipeline.analyzerID(.color, options: AnalysisOptions()) == "color.1s.t0.5.px256")
    }

    @Test func applicability() {
        let audio = MediaInfo(kind: .audio, duration: RationalTime(seconds: 1), audioChannels: 2, audioSampleRate: 48_000)
        let silentVideo = MediaInfo(kind: .video, duration: RationalTime(seconds: 1), naturalWidth: 10, naturalHeight: 10)
        let image = MediaInfo(kind: .image, duration: RationalTime(seconds: 0), naturalWidth: 10, naturalHeight: 10)
        #expect(AnalysisPipeline.applicableKinds([.events, .visual], for: audio) == [.events])
        #expect(AnalysisPipeline.applicableKinds([.events, .visual], for: silentVideo) == [.visual])
        #expect(AnalysisPipeline.applicableKinds([.events, .visual], for: image) == [.visual])
        #expect(AnalysisPipeline.applicableKinds([.color], for: image) == [.color])
        #expect(AnalysisPipeline.applicableKinds([.color], for: audio).isEmpty)
        #expect(AnalysisKind(rawValue: "events") == .events && AnalysisKind(rawValue: "visual") == .visual)
    }
}

// MARK: - Suggested colour through the compositor

@Suite struct SuggestedColorRoundTripTests {
    /// Grades the fixture dark and warm through the real compositor, measures it, then renders the suggested correction
    /// on top: the measured luma and red/blue balance must both land closer to neutral.
    @Test(.enabled(if: SignalMedia.has("bg_1080x1920_60.mov"), "Fixtures/bg_1080x1920_60.mov not present"))
    func suggestionMovesARenderedClipTowardNeutral() async throws {
        let source = try await MediaProbe.makeAsset(try #require(SignalMedia.fixture("bg_1080x1920_60.mov")))
        var preset = try #require(ExportPreset.named("master-hevc"))
        preset.sidecars = []
        func render(_ asset: MediaAsset, _ color: ColorAdjust) async throws -> MediaAsset {
            var item = Item(range: TimeRange(seconds: 0, 3), content: .media(MediaRef(asset: asset.id, source: TimeRange(seconds: 0, 3))))
            item.color = color
            let tl = Timeline(name: "c", canvas: Canvas(width: 270, height: 480), tracks: [Track(kind: .video, items: [item])])
            let out = SignalMedia.tempURL("mov")
            _ = try await Exporter.export(tl, assets: [asset.id: asset], preset: preset, to: out)
            return try await MediaProbe.makeAsset(out)
        }
        func measure(_ asset: MediaAsset) async throws -> ColorStats {
            try #require(try await AnalysisPipeline(cache: nil).analyze(asset, kinds: [.color]).color)
        }
        let graded = try await render(source, ColorAdjust(exposure: -1.5, temperature: 0.6))
        defer { try? FileManager.default.removeItem(at: graded.renderURL) }
        let before = try await measure(graded)
        let fix = ColorAdjust.suggested(for: before)
        let corrected = try await render(graded, fix)
        defer { try? FileManager.default.removeItem(at: corrected.renderURL) }
        let after = try await measure(corrected)
        print("graded \(before)\nsuggested \(fix)\ncorrected \(after)")
        #expect(fix.exposure > 0 && fix.temperature < 0)
        #expect(abs(after.luma - 0.45) < abs(before.luma - 0.45))
        #expect(abs(after.r / after.b - 1) < abs(before.r / before.b - 1))
    }
}
