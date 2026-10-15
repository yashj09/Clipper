import AVFoundation
@testable import ClipperAnalysis
import ClipperCore
import ClipperEngine
import Foundation
import Testing

/// The shared audio ingest must reproduce the per-analyzer results (one decode instead of one per analyzer).
@Suite(.serialized) struct AudioIngestEquivalenceTests {
    static func fixture(_ name: String) -> URL? {
        guard let u = FixtureLocator.directory?.appendingPathComponent(name), FileManager.default.fileExists(atPath: u.path) else { return nil }
        return u
    }

    /// speech_clean.wav as 22.05 kHz stereo (L = speech, R = 0.6 × speech + a quiet tone): exercises the downmix and
    /// a resampling ratio the fixtures don't have.
    static func stereoSpeech() async throws -> URL {
        let speech = try await AudioReader.readMono(url: try #require(fixture("speech_clean.wav")), sampleRate: 16_000)
        let x = Resampler.resample(speech, from: 16_000, to: 22_050)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clipper-stereo-\(UUID().uuidString).wav")
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 22_050, channels: 2, interleaved: false))
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(x.count)))
        buffer.frameLength = AVAudioFrameCount(x.count)
        for i in x.indices {
            buffer.floatChannelData![0][i] = x[i]
            buffer.floatChannelData![1][i] = 0.6 * x[i] + 0.01 * Float(sin(Double(i) * 0.07))
        }
        try file.write(from: buffer)
        return url
    }

    static func sources() async throws -> [URL] {
        var urls: [URL] = []
        if let u = fixture("speech_clean.wav") { urls.append(u) }
        if let u = fixture("bg_1080x1920_60.mov") { urls.append(u) }
        if let dir = FixtureLocator.directory?.appendingPathComponent("user"),
           let name = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.sorted().first(where: { $0.uppercased().hasSuffix(".MOV") }) {
            urls.append(dir.appendingPathComponent(name))
        }
        if fixture("speech_clean.wav") != nil { urls.append(try await stereoSpeech()) }
        return urls
    }

    static func expectEquivalent(_ a: SpeechActivity, _ b: SpeechActivity, _ label: String) {
        #expect(a.rms.values.count == b.rms.values.count, "\(label): envelope length \(a.rms.values.count) vs \(b.rms.values.count)")
        let worst = zip(a.rms.values, b.rms.values).filter { $0.0 > -100 || $0.1 > -100 }.map { abs($0.0 - $0.1) }.max() ?? 0
        #expect(worst < 0.01, "\(label): envelope differs by \(worst) dB")
        #expect(abs(a.noiseFloor - b.noiseFloor) < 0.01 && a.spans.count == b.spans.count, "\(label): \(a.spans.count) vs \(b.spans.count) spans")
        for (x, y) in zip(a.spans, b.spans) {
            #expect(abs(x.start - y.start) <= 0.01 && abs(x.end - y.end) <= 0.01, "\(label): span \(x) vs \(y)")
        }
    }

    /// Labels that do fire on the fixtures (speech, the tone fixture's beep), so there are events to compare.
    static let watching = SoundEventAnalyzer(labels: ["speech", "silence", "beep"])
    /// The per-analyzer reference, split into 7 s chunks read in parallel like long media.
    static var chunked: SoundEventAnalyzer {
        var a = watching
        a.chunkDuration = 7
        return a
    }

    static func expectEquivalent(_ a: SoundEvents, _ b: SoundEvents, _ label: String) {
        #expect(a.events.count == b.events.count, "\(label): \(a.events) vs \(b.events)")
        for (x, y) in zip(a.events, b.events) {
            #expect(x.label == y.label && abs(x.start - y.start) < 0.01 && abs(x.end - y.end) < 0.01
                    && abs(x.confidence - y.confidence) < 0.05, "\(label): \(x) vs \(y)")
        }
    }

    @Test(.enabled(if: fixture("speech_clean.wav") != nil, "fixtures not present"))
    func speechLoudnessAndEventsMatchTheSeparateAnalyzers() async throws {
        for url in try await Self.sources() {
            let label = url.lastPathComponent
            let info = try await MediaProbe.probe(url)
            var request = AudioIngest.Request()
            request.speech = true
            request.loudness = true
            request.events = Self.watching
            let shared = await AudioIngest.run(url: url, duration: info.duration.seconds, request: request)

            let speech = try #require(try shared.speech?.get())
            Self.expectEquivalent(speech, try await AnalysisPipeline.speechActivity(url: url, duration: info.duration.seconds), label)

            let loudness = try #require(try shared.loudness?.get())
            let reference = try await AudioFileLoudness.measure(url: url)
            #expect(abs(loudness.integrated - reference.integrated) < 0.01 && abs(loudness.truePeak - reference.truePeak) < 0.01
                    && abs(loudness.range - reference.range) < 0.01, "\(label): \(loudness) vs \(reference)")

            let events = try #require(try shared.events?.get())
            Self.expectEquivalent(events, try await Self.chunked.analyze(url: url), label)
            print("ingest ≡ separate: \(label): \(speech.spans.count) spans, \(String(format: "%.2f", loudness.integrated)) LUFS, \(events.events.count) events")
        }
    }

    @Test(.enabled(if: fixture("speech_clean.wav") != nil, "fixtures not present"))
    func streamedTranscriptMatchesTheFileTranscript() async throws {
        for url in [try #require(Self.fixture("speech_clean.wav")), try await Self.stereoSpeech()] {
            let info = try await MediaProbe.probe(url)
            var request = AudioIngest.Request()
            request.speech = true
            request.transcriber = AppleTranscriber()
            let shared = await AudioIngest.run(url: url, duration: info.duration.seconds, request: request)
            let streamed = try #require(try shared.transcript?.get())
            let file = try await AppleTranscriber().transcribe(url: url, locale: Locale(identifier: "en-US"))
            let a = streamed.words.map { $0.text.lowercased() }, b = file.words.map { $0.text.lowercased() }
            let distance = Self.editDistance(a, b)
            print("streamed transcript \(url.lastPathComponent): \(a.count) words vs \(b.count) from the file, edit distance \(distance)")
            #expect(Double(distance) <= 0.02 * Double(b.count), "\(a.joined(separator: " "))\nvs\n\(b.joined(separator: " "))")
            // Word edges: within one or two of the recognizer's ~20-60 ms time steps (the snapper refines them later anyway).
            if a == b {
                let worst = zip(streamed.words, file.words).map { max(abs($0.start - $1.start), abs($0.end - $1.end)) }.max() ?? 0
                print("  word edges differ by up to \(worst) s")
                #expect(worst <= 0.08, "word timing differs by up to \(worst) s")
            }
        }
    }

    @Test func cancellationStopsTheIngest() async throws {
        guard let url = Self.fixture("speech_clean.wav") else { return }
        for delay in [0, 10, 50, 150, 400, 1000] {   // before, during and after the transcriber's setup and the decode
            let task = Task {
                var request = AudioIngest.Request()
                request.speech = true
                request.events = SoundEventAnalyzer()
                request.transcriber = AppleTranscriber()
                return await AudioIngest.run(url: url, duration: 36, request: request)
            }
            try await Task.sleep(for: .milliseconds(delay))
            task.cancel()
            let r = await task.value
            // Either it finished first or every kind reports the cancellation; it never hangs.
            for result in [r.speech.map { $0.map { _ in () } }, r.events.map { $0.map { _ in () } }, r.transcript.map { $0.map { _ in () } }] {
                if case .failure(let error) = result { #expect(error is CancellationError, "\(delay) ms: \(error)") }
            }
        }
    }

    @Test func consumerFailureOnlyFailsItsKind() async throws {
        guard let url = Self.fixture("speech_clean.wav") else { return }
        var request = AudioIngest.Request()
        request.speech = true
        request.loudness = true
        request.events = SoundEventAnalyzer(labels: ["not_a_label"])
        let r = await AudioIngest.run(url: url, duration: 36, request: request)
        #expect(throws: SoundEventError.self) { try r.events?.get() }
        #expect((try? r.speech?.get()) != nil && (try? r.loudness?.get()) != nil)
    }

    @Test(.enabled(if: fixture("speech_clean.wav") != nil, "fixtures not present"))
    func pipelineUsesOneDecodeAndCachesEveryKind() async throws {
        let url = try #require(Self.fixture("speech_clean.wav"))
        let asset = try await MediaProbe.makeAsset(url)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clipper-ingest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = DirectoryAnalysisCache(directory: dir)
        let kinds: Set<AnalysisKind> = [.speech, .transcript, .loudness, .events]
        #expect(AnalysisPipeline.sharedAudioKinds(kinds, options: AnalysisOptions()) == kinds)
        #expect(AnalysisPipeline.sharedAudioKinds([.events], options: AnalysisOptions()).isEmpty)       // alone: chunked reader
        #expect(AnalysisPipeline.sharedAudioKinds([.loudness, .events], options: AnalysisOptions()) == [.loudness, .events])
        let a = try await AnalysisPipeline(cache: cache).analyze(asset, kinds: kinds)
        let b = try await AnalysisPipeline(cache: cache).analyze(asset, kinds: kinds)
        #expect(a == b)
        #expect(a.transcript.map { !$0.words.isEmpty } == true && a.speech != nil && a.loudness != nil && a.events != nil)
        for kind in kinds {
            let file = cache.fileURL(key: asset.key, analyzer: AnalysisPipeline.analyzerID(kind, options: AnalysisOptions()),
                                     version: AnalysisPipeline.version(of: kind))
            #expect(FileManager.default.fileExists(atPath: file.path), "\(kind) not cached")
        }
    }

    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)) }
            prev = cur
        }
        return prev[b.count]
    }
}
