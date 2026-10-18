import AVFoundation
@testable import ClipperAnalysis
import ClipperCore
import ClipperEngine
import CoreImage
import Foundation
import Synchronization
import Testing

// MARK: - Helpers

private struct Truth: Decodable {
    struct Sentence: Decodable { var text: String; var start: Double; var end: Double }
    var duration: Double
    var sentences: [Sentence]
}

private enum TestMedia {
    static var dir: URL? { FixtureLocator.directory }
    static func fixture(_ name: String) -> URL? {
        guard let d = dir else { return nil }
        let u = d.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
    static var hasSpeech: Bool { fixture("speech_clean.wav") != nil }
    static var userClip: URL? {
        guard let d = dir?.appendingPathComponent("user"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: d.path) else { return nil }
        return names.sorted().first { $0.uppercased().hasSuffix(".MOV") }.map { d.appendingPathComponent($0) }
    }

    static func truth() throws -> Truth {
        try JSONDecoder().decode(Truth.self, from: Data(contentsOf: try #require(fixture("speech_truth.json"))))
    }

    static func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("clipper-test-\(UUID().uuidString).\(ext)")
    }

    /// Writes mono Float samples as a 16-bit WAV.
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

    /// A .mov with the video of `video` (looped to cover the audio) and the audio of `audio`, passthrough.
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

    static func norm(_ w: String) -> String {
        let s = w.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" }
        return ["1st": "first", "2nd": "second", "3rd": "third"][s] ?? s
    }

    static func words(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map { norm(String($0)) }.filter { !$0.isEmpty } }

    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        var prev = Array(0...b.count)
        for i in 1...max(1, a.count) where !a.isEmpty {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(1, b.count) where !b.isEmpty {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return a.isEmpty ? b.count : prev[b.count]
    }

    static func median(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? .nan : s[s.count / 2] }

    /// Per truth sentence: |nearest word start − sentence start| and |nearest word end − sentence end| (seconds).
    static func boundaryErrors(_ words: [TranscriptWord], _ truth: Truth) -> (starts: [Double], ends: [Double]) {
        let starts = truth.sentences.map { s in words.map { abs($0.start - s.start) }.min() ?? .infinity }
        let ends = truth.sentences.map { s in words.map { abs($0.end - s.end) }.min() ?? .infinity }
        return (starts, ends)
    }
}

private func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }

// MARK: - Fakes

private final class FakeTranscriber: Transcriber {
    let calls = Mutex(0)
    var id: String { "fake" }
    func transcribe(url: URL, locale: Locale, range: ClosedRange<Double>?) async throws -> Transcript {
        calls.withLock { $0 += 1 }
        return Transcript(locale: locale.identifier, engine: id, words: [
            TranscriptWord(text: "hello", start: 0.55, end: 0.8),
            TranscriptWord(text: "um", start: 1.55, end: 1.7),
        ])
    }
}

private final class CountingCache: AnalysisCache {
    let inner: DirectoryAnalysisCache
    let hits = Mutex(0), misses = Mutex(0), stores = Mutex(0)
    init(directory: URL) { inner = DirectoryAnalysisCache(directory: directory) }
    func load(key: AssetKey, analyzer: String, version: Int) async -> Data? {
        let d = await inner.load(key: key, analyzer: analyzer, version: version)
        if d == nil { misses.withLock { $0 += 1 } } else { hits.withLock { $0 += 1 } }
        return d
    }
    func store(_ data: Data, key: AssetKey, analyzer: String, version: Int) async throws {
        stores.withLock { $0 += 1 }
        try await inner.store(data, key: key, analyzer: analyzer, version: version)
    }
}

// MARK: - Transcription (Apple)

@Suite(.serialized) struct TranscriptionTests {
    @Test(.enabled(if: TestMedia.hasSpeech, "Fixtures/speech_clean.wav not present"))
    func appleTranscribesCleanSpeech() async throws {
        let url = try #require(TestMedia.fixture("speech_clean.wav"))
        let truth = try TestMedia.truth()
        let clock = ContinuousClock(), t0 = clock.now
        let transcript = try await AppleTranscriber().transcribe(url: url, locale: Locale(identifier: "en-US"), range: nil)
        let elapsed = seconds(clock.now - t0)

        let text = TestMedia.words(transcript.text).joined(separator: " ")
        #expect(text.contains("automatic video editor"))
        #expect(text.contains("subscriptions"))
        #expect(transcript.engine == "apple")
        #expect(transcript.locale.hasPrefix("en"))
        #expect(zip(transcript.words, transcript.words.dropFirst()).allSatisfy { $0.start <= $1.start })
        #expect(transcript.words.allSatisfy { $0.end >= $0.start && $0.confidence != nil })

        let ref = truth.sentences.flatMap { TestMedia.words($0.text) }
        let hyp = TestMedia.words(transcript.text)
        let wer = Double(TestMedia.editDistance(ref, hyp)) / Double(ref.count)
        let raw = TestMedia.boundaryErrors(transcript.words, truth)
        print(String(format: "apple raw: %d words, WER %.1f%%, %.2fs (%.0f× realtime), start err med %.0f ms, end err med %.0f ms",
                     transcript.words.count, wer * 100, elapsed, truth.duration / elapsed,
                     TestMedia.median(raw.starts) * 1000, TestMedia.median(raw.ends) * 1000))
        #expect(wer < 0.08)
    }

    @Test(.enabled(if: TestMedia.hasSpeech, "Fixtures/speech_clean.wav not present"))
    func pipelineSnapsSentenceBoundaries() async throws {
        let url = try #require(TestMedia.fixture("speech_clean.wav"))
        let truth = try TestMedia.truth()
        let asset = try await MediaProbe.makeAsset(url)
        let pipeline = AnalysisPipeline(cache: nil)
        let analysis = try await pipeline.analyze(asset, kinds: [.transcript, .loudness])
        let transcript = try #require(analysis.transcript)
        #expect(analysis.speech != nil)        // computed for the snapper and returned
        #expect(analysis.loudness != nil)
        #expect(analysis.faces == nil && analysis.beats == nil)

        let (starts, ends) = TestMedia.boundaryErrors(transcript.words, truth)
        print(String(format: "pipeline snapped: start err med %.0f ms (max %.0f), end err med %.0f ms (max %.0f); "
                     + "loudness %.1f LUFS; fillers %@",
                     TestMedia.median(starts) * 1000, (starts.max() ?? 0) * 1000,
                     TestMedia.median(ends) * 1000, (ends.max() ?? 0) * 1000,
                     analysis.loudness?.integrated ?? .nan,
                     transcript.words.filter(\.isFiller).map(\.text).joined(separator: ",")))
        #expect(TestMedia.median(starts) < 0.06)
        #expect(TestMedia.median(ends) < 0.06)
        // Snapping keeps words ordered and non-overlapping.
        #expect(zip(transcript.words, transcript.words.dropFirst()).allSatisfy { $0.end <= $1.start + 1e-9 })
    }

    @Test(.enabled(if: TestMedia.hasSpeech && TestMedia.fixture("overlay_1280x720_30.mov") != nil, "fixtures not present"))
    func transcribesVideoFileAndRanges() async throws {
        let wav = try #require(TestMedia.fixture("speech_clean.wav"))
        let video = try #require(TestMedia.fixture("overlay_1280x720_30.mov"))
        let mov = TestMedia.tempURL("mov")
        defer { try? FileManager.default.removeItem(at: mov) }
        try await TestMedia.mux(video: video, audio: wav, to: mov)
        let info = try await MediaProbe.probe(mov)
        #expect(info.hasVideo && info.hasAudio)

        let apple = AppleTranscriber(), en = Locale(identifier: "en-US")
        let fromWav = try await apple.transcribe(url: wav, locale: en, range: nil)
        let fromMov = try await apple.transcribe(url: mov, locale: en, range: nil)
        let d = TestMedia.editDistance(TestMedia.words(fromWav.text), TestMedia.words(fromMov.text))
        print("video transcript: \(fromMov.words.count) words (wav \(fromWav.words.count)), edit distance \(d)")
        #expect(d <= 3)

        // A range is transcribed in source time: words land inside it, near the same words of the full pass.
        let part = try await apple.transcribe(url: mov, locale: en, range: 10.0...22.0)
        #expect(!part.words.isEmpty)
        #expect(part.words.allSatisfy { $0.start >= 9.95 && $0.end <= 22.05 })
        let full = fromMov.words.filter { $0.start >= 10.2 && $0.end <= 21.8 }
        var matched = 0
        for w in full {
            if part.words.contains(where: { TestMedia.norm($0.text) == TestMedia.norm(w.text) && abs($0.start - w.start) < 0.25 }) {
                matched += 1
            }
        }
        print("range 10–22 s: \(part.words.count) words, \(matched)/\(full.count) match the full pass within 250 ms")
        #expect(Double(matched) >= 0.8 * Double(full.count))
    }

    @Test(.enabled(if: TestMedia.fixture("bg_1080x1920_60.mov") != nil, "Fixtures/bg_1080x1920_60.mov not present"))
    func toneOnlyVideoYieldsFewWords() async throws {
        let url = try #require(TestMedia.fixture("bg_1080x1920_60.mov"))
        let t = try await AppleTranscriber().transcribe(url: url, locale: Locale(identifier: "en-US"), range: nil)
        print("sine-tone video: \(t.words.count) words “\(t.text)”")
        #expect(t.words.count <= 3)
    }

    @Test func videoWithoutAudioThrowsNoAudioTrack() async throws {
        guard let url = TestMedia.fixture("rotated_marker.mov") else { return }
        await #expect(throws: AudioReaderError.self) {
            _ = try await AppleTranscriber().transcribe(url: url, locale: Locale(identifier: "en-US"), range: nil)
        }
    }
}

// MARK: - Whisper (optional)

@Suite struct WhisperTests {
    static let model = URL(fileURLWithPath: "/Users/yashjain/dev/Personal Projects/Clipper/models/ggml-base.en.bin")

    @Test func parsesWordJSON() throws {
        let json = #"""
        {"transcription":[{"offsets":{"from":0,"to":10},"text":""},
          {"offsets":{"from":10,"to":440},"text":" Welcome"},
          {"offsets":{"from":440,"to":680},"text":" back"},
          {"offsets":{"from":700,"to":900},"text":" [BLANK_AUDIO]"},
          {"offsets":{"from":900,"to":1300},"text":" Um,"}]}
        """#
        let words = try WhisperTranscriber.parse(Data(json.utf8))
        #expect(words.map(\.text) == ["Welcome", "back", "Um,"])
        #expect(abs(words[0].start - 0.01) < 1e-9 && abs(words[0].end - 0.44) < 1e-9)
        #expect(Fillers.markFillers(words).last?.isFiller == true)
    }

    @Test(.enabled(if: TestMedia.hasSpeech && WhisperTranscriber.isAvailable(modelPath: WhisperTests.model), "whisper-cli/model not installed"))
    func whisperTranscribesCleanSpeech() async throws {
        let url = try #require(TestMedia.fixture("speech_clean.wav"))
        let w = WhisperTranscriber(modelPath: Self.model)
        #expect(w.id == "whisper-ggml-base.en")
        let clock = ContinuousClock(), t0 = clock.now
        let t = try await w.transcribe(url: url, locale: Locale(identifier: "en-US"), range: nil)
        let elapsed = seconds(clock.now - t0)
        let text = TestMedia.words(t.text).joined(separator: " ")
        print(String(format: "whisper base.en: %d words in %.2fs; fillers: %@", t.words.count, elapsed,
                     t.words.filter(\.isFiller).map(\.text).joined(separator: ",")))
        #expect(text.contains("automatic video editor"))
        #expect(text.contains("subscriptions"))
    }
}

// MARK: - Pipeline mechanics

@Suite struct PipelineMechanicsTests {
    /// 3 s of quiet noise with two tone "words", as a 16 kHz WAV.
    static func syntheticSpeechWAV() throws -> URL {
        let sr = 16_000.0
        var x = Signal.noise(count: Int(3 * sr), rmsDB: -60, seed: 7)
        Signal.addTone(&x, start: 0.5, end: 1.0, sampleRate: sr)
        Signal.addTone(&x, start: 1.5, end: 1.9, sampleRate: sr)
        let url = TestMedia.tempURL("wav")
        try TestMedia.writeWAV(x, sampleRate: sr, to: url)
        return url
    }

    @Test func secondCallIsServedFromCache() async throws {
        let wav = try Self.syntheticSpeechWAV()
        let dir = TestMedia.tempURL("cache")
        defer { try? FileManager.default.removeItem(at: wav); try? FileManager.default.removeItem(at: dir) }
        let asset = try await MediaProbe.makeAsset(wav)
        let fake = FakeTranscriber()
        let cache = CountingCache(directory: dir)
        let pipeline = AnalysisPipeline(cache: cache, options: AnalysisOptions(transcriber: fake))
        let progress = Mutex<[AnalysisKind: Double]>([:])
        let kinds: Set<AnalysisKind> = [.transcript, .loudness, .faces]   // faces doesn't apply to an audio file

        let first = try await pipeline.analyze(asset, kinds: kinds) { kind, p in progress.withLock { $0[kind] = p } }
        #expect(fake.calls.withLock { $0 } == 1)
        #expect(cache.stores.withLock { $0 } == 3)                 // speech, transcript (raw), loudness
        #expect(cache.hits.withLock { $0 } == 0)
        #expect(progress.withLock { $0 } == [.speech: 1, .transcript: 1, .loudness: 1])
        #expect(first.faces == nil && first.beats == nil && first.speech != nil)

        // Snapped: "hello" (0.55–0.8 raw) grows to the tone burst 0.5–1.0; "um" is a filler.
        let words = try #require(first.transcript?.words)
        #expect(abs(words[0].end - 1.0) < 0.03)
        #expect(abs(words[0].start - 0.5) < 0.03)
        #expect(words[1].isFiller)

        let second = try await pipeline.analyze(asset, kinds: kinds)
        #expect(fake.calls.withLock { $0 } == 1)                    // transcriber not called again
        #expect(cache.hits.withLock { $0 } == 3)
        #expect(cache.stores.withLock { $0 } == 3)
        #expect(second == first)

        let file = DirectoryAnalysisCache(directory: dir)
            .fileURL(key: asset.key, analyzer: "transcript.fake.en-US", version: AnalysisPipeline.version(of: .transcript))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func keywordsComeWithTheirTranscriptAndAreCached() async throws {
        struct Scripted: Transcriber {
            var id: String { "scripted" }
            func transcribe(url: URL, locale: Locale, range: ClosedRange<Double>?) async throws -> Transcript {
                Transcript(locale: locale.identifier, engine: id, words: [
                    TranscriptWord(text: "um", start: 0.5, end: 0.6), TranscriptWord(text: "camera", start: 0.6, end: 1.0),
                    TranscriptWord(text: "300", start: 1.5, end: 1.9),
                ])
            }
        }
        let wav = try Self.syntheticSpeechWAV()
        let dir = TestMedia.tempURL("cache")
        defer { try? FileManager.default.removeItem(at: wav); try? FileManager.default.removeItem(at: dir) }
        let asset = try await MediaProbe.makeAsset(wav)
        let cache = CountingCache(directory: dir)
        let pipeline = AnalysisPipeline(cache: cache, options: AnalysisOptions(transcriber: Scripted()))

        let first = try await pipeline.analyze(asset, kinds: [.keywords])
        #expect(first.transcript?.words.count == 3 && first.speech != nil)
        let tags = try #require(first.keywords?.tags)
        #expect(tags.map(\.word) == [1, 2])
        #expect(tags.map(\.kind) == [.noun, .number])
        #expect(tags.first?.emoji == "📷")
        #expect(cache.stores.withLock { $0 } == 3)                 // speech, transcript, keywords

        let second = try await pipeline.analyze(asset, kinds: [.keywords])
        #expect(second == first)
        #expect(cache.stores.withLock { $0 } == 3)
        #expect(AnalysisPipeline.analyzerID(.keywords, options: AnalysisOptions(transcriber: Scripted()))
            == "keywords.transcript.scripted.en-US.t\(AnalysisPipeline.version(of: .transcript))")
    }

    @Test func versionMismatchIsAMiss() async throws {
        let dir = TestMedia.tempURL("cache")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = DirectoryAnalysisCache(directory: dir)
        let key = AssetKey("abc")
        try await cache.store(Data("1".utf8), key: key, analyzer: "x/y", version: 1)
        #expect(await cache.load(key: key, analyzer: "x/y", version: 1) == Data("1".utf8))
        #expect(await cache.load(key: key, analyzer: "x/y", version: 2) == nil)
        #expect(cache.fileURL(key: key, analyzer: "x/y", version: 1).lastPathComponent == "x_y@1.json")
    }

    @Test func cacheCodecRoundTripsInfiniteLoudness() throws {
        let silent = LoudnessInfo(integrated: -.infinity, truePeak: -.infinity, range: 0)
        let data = try CacheCodec.encoder.encode(silent)
        #expect(try CacheCodec.decoder.decode(LoudnessInfo.self, from: data) == silent)
    }

    @Test func applicability() {
        let audio = MediaInfo(kind: .audio, duration: RationalTime(seconds: 1), audioChannels: 2, audioSampleRate: 48_000)
        let silentVideo = MediaInfo(kind: .video, duration: RationalTime(seconds: 1), naturalWidth: 10, naturalHeight: 10)
        let all = Set(AnalysisKind.allCases)
        #expect(AnalysisPipeline.applicableKinds(all, for: audio) == [.speech, .transcript, .loudness, .beats, .events, .keywords])
        #expect(AnalysisPipeline.applicableKinds(all, for: silentVideo) == [.faces, .visual])
    }

    @Test func noAudioAssetSkipsAudioKinds() async throws {
        guard let url = TestMedia.fixture("rotated_marker.mov") else { return }
        let asset = try await MediaProbe.makeAsset(url)
        let fake = FakeTranscriber()
        let a = try await AnalysisPipeline(cache: nil, options: AnalysisOptions(transcriber: fake))
            .analyze(asset, kinds: Set(AnalysisKind.allCases))
        #expect(a.transcript == nil && a.speech == nil && a.loudness == nil && a.beats == nil && a.events == nil)
        #expect(a.faces == FaceTrack(samples: []))
        #expect(a.visual != nil)
        #expect(fake.calls.withLock { $0 } == 0)
    }

    @Test func failuresCarryPartialResults() async throws {
        struct Broken: Transcriber {
            var id: String { "broken" }
            func transcribe(url: URL, locale: Locale, range: ClosedRange<Double>?) async throws -> Transcript {
                throw TranscriptionError.failed("boom")
            }
        }
        let wav = try Self.syntheticSpeechWAV()
        defer { try? FileManager.default.removeItem(at: wav) }
        let asset = try await MediaProbe.makeAsset(wav)
        do {
            _ = try await AnalysisPipeline(cache: nil, options: AnalysisOptions(transcriber: Broken()))
                .analyze(asset, kinds: [.transcript, .loudness])
            Issue.record("expected a failure")
        } catch AnalysisPipelineError.analyzersFailed(let errors, let partial) {
            #expect(Array(errors.keys) == [.transcript])
            #expect(partial.loudness != nil && partial.speech != nil && partial.transcript == nil)
        }
    }

    @Test func cancellationStopsAnalysis() async throws {
        guard let url = TestMedia.fixture("bg_1080x1920_60.mov") else { return }
        let asset = try await MediaProbe.makeAsset(url)
        let task = Task { try await AnalysisPipeline(cache: nil).analyze(asset, kinds: [.faces]) }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}

// MARK: - Faces

@Suite struct FaceAnalyzerTests {
    @Test func orientationMapping() {
        #expect(FaceAnalyzer.orientation(rotation: 0, mirrored: false) == .up)
        #expect(FaceAnalyzer.orientation(rotation: 90, mirrored: false) == .right)
        #expect(FaceAnalyzer.orientation(rotation: 180, mirrored: false) == .down)
        #expect(FaceAnalyzer.orientation(rotation: 270, mirrored: false) == .left)
        #expect(FaceAnalyzer.orientation(rotation: 0, mirrored: true) == .upMirrored)
        #expect(FaceAnalyzer.orientation(rotation: 90, mirrored: true) == .leftMirrored)
        #expect(FaceAnalyzer.orientation(rotation: -90, mirrored: false) == .left)
    }

    @Test func visionRectToTopLeft() {
        let r = FaceAnalyzer.topLeftRect(CGRect(x: 0.1, y: 0.6, width: 0.2, height: 0.3))
        #expect(abs(r.x - 0.1) < 1e-9 && abs(r.y - 0.1) < 1e-9 && abs(r.width - 0.2) < 1e-9 && abs(r.height - 0.3) < 1e-9)
        let clamped = FaceAnalyzer.topLeftRect(CGRect(x: -0.1, y: 0.9, width: 0.3, height: 0.3))
        #expect(clamped.x == 0 && clamped.y == 0 && abs(clamped.width - 0.2) < 1e-9 && abs(clamped.height - 0.1) < 1e-9)
    }

    /// The orientation handed to Vision must turn stored frames upright: rotated_marker.mov stores a red marker in
    /// the natural top-left corner and is tagged rotate-90°-clockwise, so displayed upright the marker is top-right.
    @Test(.enabled(if: TestMedia.fixture("rotated_marker.mov") != nil, "Fixtures/rotated_marker.mov not present"))
    func orientationPutsMarkerTopRight() async throws {
        let url = try #require(TestMedia.fixture("rotated_marker.mov"))
        let info = try await MediaProbe.probe(url)
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        #expect(reader.startReading())
        let sample = try #require(output.copyNextSampleBuffer())
        let pixels = try #require(CMSampleBufferGetImageBuffer(sample))
        reader.cancelReading()

        let image = CIImage(cvPixelBuffer: pixels).oriented(FaceAnalyzer.orientation(rotation: info.rotation, mirrored: info.mirrored))
        #expect(Int(image.extent.width) == info.displayWidth && Int(image.extent.height) == info.displayHeight)
        let w = Int(image.extent.width), h = Int(image.extent.height)
        // CGImage → bitmap context: memory row 0 is the top of the displayed image.
        let cg = try #require(CIContext().createCGImage(image, from: image.extent))
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        rgba.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        func isRed(_ x: Int, _ y: Int) -> Bool {
            let i = (y * w + x) * 4
            return rgba[i] > 150 && rgba[i + 1] < 100 && rgba[i + 2] < 100
        }
        let m = 10
        let corners = (tl: isRed(m, m), tr: isRed(w - m, m), bl: isRed(m, h - m), br: isRed(w - m, h - m))
        print("rotated_marker rotation \(info.rotation) mirrored \(info.mirrored), red corners: \(corners)")
        #expect(corners.tr && !corners.tl && !corners.bl && !corners.br)
    }

    @Test(.enabled(if: TestMedia.fixture("rotated_marker.mov") != nil, "Fixtures/rotated_marker.mov not present"))
    func noFacesInMarkerClip() async throws {
        let url = try #require(TestMedia.fixture("rotated_marker.mov"))
        let info = try await MediaProbe.probe(url)
        let progress = Mutex(0.0)
        let track = try await FaceAnalyzer().analyze(url: url, info: info, range: nil) { p in progress.withLock { $0 = p } }
        #expect(track.samples.isEmpty)
        #expect(progress.withLock { $0 } == 1)
    }

    @Test(.enabled(if: TestMedia.userClip != nil, "no clip in Fixtures/user"))
    func runsOnUserClip() async throws {
        let url = try #require(TestMedia.userClip)
        let info = try await MediaProbe.probe(url)
        let clock = ContinuousClock(), t0 = clock.now
        let track = try await FaceAnalyzer().analyze(url: url, info: info)
        let elapsed = seconds(clock.now - t0)
        let duration = info.duration.seconds
        print(String(format: "%@: rotation %d, %.1fs @ %.1f fps → %d face samples in %.2fs (%.0f source fps decoded, %.1f× realtime)",
                     url.lastPathComponent, info.rotation, duration, info.frameRate, track.samples.count, elapsed,
                     duration * info.frameRate / elapsed, duration / elapsed))
        if let s = track.samples.first {
            print("  first face t=\(s.time) rect=\(s.rect) conf=\(s.confidence)")
        }
        #expect(track.samples.allSatisfy { $0.rect.x >= 0 && $0.rect.y >= 0 && $0.rect.x + $0.rect.width <= 1 + 1e-9
            && $0.rect.y + $0.rect.height <= 1 + 1e-9 && $0.time >= 0 && $0.time <= duration + 0.1 })
        #expect(zip(track.samples, track.samples.dropFirst()).allSatisfy { $1.time - $0.time >= 0.2 })
    }

    @Test(.enabled(if: TestMedia.userClip != nil, "no clip in Fixtures/user"))
    func fullPipelineOnUserClip() async throws {
        let url = try #require(TestMedia.userClip)
        let asset = try await MediaProbe.makeAsset(url)
        let dir = TestMedia.tempURL("cache")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pipeline = AnalysisPipeline(cache: DirectoryAnalysisCache(directory: dir))
        let clock = ContinuousClock(), t0 = clock.now
        let a = try await pipeline.analyze(asset, kinds: Set(AnalysisKind.allCases))
        let cold = seconds(clock.now - t0)
        let t1 = clock.now
        let b = try await pipeline.analyze(asset, kinds: Set(AnalysisKind.allCases))
        let warm = seconds(clock.now - t1)
        print(String(format: "user clip pipeline: cold %.2fs, cached %.3fs; %d words, %d speech spans, %.1f LUFS, %d faces",
                     cold, warm, a.transcript?.words.count ?? 0, a.speech?.spans.count ?? 0,
                     a.loudness?.integrated ?? .nan, a.faces?.samples.count ?? 0))
        print("  “\(a.transcript?.text.prefix(160) ?? "")”")
        #expect(a == b)
        #expect(a.beats == nil)
    }
}

// MARK: - Music

@Suite struct MusicAnalyzerTests {
    @Test func clickTrackTempo() async throws {
        let sr = 44_100.0, bpm = 128.0, length = 30.0
        var x = [Float](repeating: 0, count: Int(length * sr))
        var t = 0.25
        var k = 0
        while t < length - 0.1 {
            let start = Int(t * sr)
            let accent: Float = k % 4 == 0 ? 0.9 : 0.6
            for i in 0..<Int(0.03 * sr) where start + i < x.count {
                let env = expf(-Float(i) / Float(0.006 * sr))
                x[start + i] += accent * env * Float(sin(2 * .pi * 1_500 * Double(i) / sr))
            }
            t += 60 / bpm
            k += 1
        }
        let url = TestMedia.tempURL("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try TestMedia.writeWAV(x, sampleRate: sr, to: url)

        let (beats, energy, duration) = try await MusicAnalyzer.analyze(url: url)
        print(String(format: "click track: %.2f BPM (truth %.0f), %d beats, energy %.2f, %.2fs", beats.bpm, bpm,
                     beats.beats.count, energy, duration))
        #expect(abs(beats.bpm - bpm) / bpm < 0.02)
        #expect(abs(duration - length) < 0.05)
        #expect(energy > 0 && energy < 1)
        #expect(beats.beats.count > 55)
    }

    @Test func pipelineRunsBeatsForAudioAssets() async throws {
        let sr = 22_050.0
        var x = [Float](repeating: 0, count: Int(10 * sr))
        var t = 0.1
        while t < 9.9 {
            for i in 0..<300 where Int(t * sr) + i < x.count { x[Int(t * sr) + i] = 0.8 * expf(-Float(i) / 60) }
            t += 0.5
        }
        let url = TestMedia.tempURL("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try TestMedia.writeWAV(x, sampleRate: sr, to: url)
        let asset = try await MediaProbe.makeAsset(url)
        let a = try await AnalysisPipeline(cache: nil, options: AnalysisOptions(transcriber: FakeTranscriber()))
            .analyze(asset, kinds: [.beats])
        let grid = try #require(a.beats)
        #expect(abs(grid.bpm - 120) < 2.4)
        #expect(a.transcript == nil && a.speech == nil)
    }
}

@Suite struct CachePathSafetyTests {
    @Test func cachePathsStayInsideDirectory() {
        let dir = URL(fileURLWithPath: "/tmp/clipper-cache-test", isDirectory: true)
        let cache = DirectoryAnalysisCache(directory: dir)
        for key in ["..", ".", "", "../../etc", ".hidden", "a/../../b"] {
            for analyzer in ["..", "speech", "../x"] {
                let url = cache.fileURL(key: AssetKey(key), analyzer: analyzer, version: 1).standardizedFileURL
                #expect(url.path.hasPrefix(dir.path + "/"), "\(key) / \(analyzer) → \(url.path)")
            }
        }
    }
}
