import ClipperAnalysis
import ClipperCore
import Foundation
import Testing

// MARK: - Signal helpers (shared with BeatTrackerTests)

/// Deterministic PRNG so synthetic signals are reproducible.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum Signal {
    static func sine(freq: Double, amplitude: Float, seconds: Double, sampleRate: Double) -> [Float] {
        let n = Int(seconds * sampleRate)
        return (0..<n).map { amplitude * Float(sin(2 * .pi * freq * Double($0) / sampleRate)) }
    }

    /// Uniform white noise with the given RMS level in dBFS.
    static func noise(count: Int, rmsDB: Float, seed: UInt64) -> [Float] {
        var rng = SplitMix64(seed: seed)
        let a = powf(10, rmsDB / 20) * sqrtf(3)
        return (0..<count).map { _ in Float.random(in: -a...a, using: &rng) }
    }

    /// Adds a tone of `amplitude` over [start, end) seconds.
    static func addTone(_ x: inout [Float], start: Double, end: Double, freq: Double = 220, amplitude: Float = 0.3,
                        sampleRate: Double) {
        let a = max(0, Int(start * sampleRate)), b = min(x.count, Int(end * sampleRate))
        guard a < b else { return }
        for i in a..<b { x[i] += amplitude * Float(sin(2 * .pi * freq * Double(i) / sampleRate)) }
    }
}

// MARK: - RMS envelope

@Suite struct RMSTests {
    @Test func sineAtHalfAmplitudeIsMinus9dB() {
        let sr = 48_000.0
        let x = Signal.sine(freq: 1000, amplitude: 0.5, seconds: 1, sampleRate: sr)
        let env = Envelope.rms(samples: x, sampleRate: sr)
        #expect(env.values.count == 100)
        #expect(abs(env.hop - 0.01) < 1e-12)
        for v in env.values { #expect(abs(v - (-9.0309)) < 0.1) }
    }

    @Test func silenceClampsToMinus120() {
        let env = Envelope.rms(samples: [Float](repeating: 0, count: 16_000), sampleRate: 16_000)
        #expect(env.values.count == 100)
        #expect(env.values.allSatisfy { $0 == -120 })
    }

    @Test func hopIsWholeSamples() {
        let env = Envelope.rms(samples: [Float](repeating: 0.1, count: 22_050), sampleRate: 22_050)
        // 10 ms at 22.05 kHz is 220.5 samples → 221 samples per hop.
        #expect(abs(env.hop - 221.0 / 22_050) < 1e-12)
        #expect(env.values.count == 22_050 / 221)
        #expect(Envelope.rms(samples: [], sampleRate: 16_000).values.isEmpty)
    }

    /// Wall-clock benchmark: only meaningful on an idle machine, so opt-in (CLIPPER_PERF_TESTS=1).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLIPPER_PERF_TESTS"] == "1")) func oneHourAt16kIsFast() {
        let sr = 16_000.0
        let x = Signal.noise(count: Int(3600 * sr), rmsDB: -30, seed: 7)
        let clock = ContinuousClock()
        let start = clock.now
        let env = Envelope.rms(samples: x, sampleRate: sr)
        let elapsed = clock.now - start
        print("RMS envelope, 1 h @ 16 kHz: \(elapsed)")
        #expect(env.values.count == 360_000)
        #expect(elapsed < .seconds(1))
    }
}

// MARK: - Activity detection

/// Bursts of `tone` / gaps of silence over -60 dB noise.
struct BurstFixture {
    let sr = 16_000.0
    var bursts: [(Double, Double)]
    var samples: [Float]

    init(bursts: [(Double, Double)], duration: Double) {
        self.bursts = bursts
        samples = Signal.noise(count: Int(duration * sr), rmsDB: -60, seed: 42)
        for (a, b) in bursts { Signal.addTone(&samples, start: a, end: b, sampleRate: sr) }
    }

    static func regular(count: Int = 5, offset: Double = 0.305, tone: Double = 0.5, gap: Double = 0.7) -> BurstFixture {
        let bursts = (0..<count).map { i -> (Double, Double) in
            let a = offset + Double(i) * (tone + gap)
            return (a, a + tone)
        }
        return BurstFixture(bursts: bursts, duration: offset + Double(count) * (tone + gap) + 0.5)
    }

    var activity: SpeechActivity {
        SpeechActivityDetector().detect(Envelope.rms(samples: samples, sampleRate: sr))
    }
}

@Suite struct SpeechActivityDetectorTests {
    @Test func toneBurstsGiveOneSpanEach() {
        let fx = BurstFixture.regular()
        let act = fx.activity
        #expect(act.spans.count == fx.bursts.count)
        #expect(abs(act.noiseFloor - -60) < 2)
        #expect(act.threshold == -50)
        for (span, burst) in zip(act.spans, fx.bursts) {
            #expect(abs(span.start - burst.0) <= 0.02, "start \(span.start) vs \(burst.0)")
            #expect(abs(span.end - burst.1) <= 0.02, "end \(span.end) vs \(burst.1)")
        }
    }

    @Test func mergesShortGapsAndDropsBlips() {
        // Two tones 100 ms apart (< minSilence 150 ms) → one span; a 50 ms blip (< minSpeech 100 ms) → dropped;
        // two tones 300 ms apart → separate spans.
        let fx = BurstFixture(bursts: [(0.5, 1.0), (1.1, 1.6), (2.5, 2.55), (3.5, 4.0), (4.3, 4.8)], duration: 5.5)
        let spans = fx.activity.spans
        #expect(spans.count == 3)
        guard spans.count == 3 else { return }
        #expect(abs(spans[0].start - 0.5) <= 0.02 && abs(spans[0].end - 1.6) <= 0.02)
        #expect(abs(spans[1].start - 3.5) <= 0.02 && abs(spans[1].end - 4.0) <= 0.02)
        #expect(abs(spans[2].start - 4.3) <= 0.02 && abs(spans[2].end - 4.8) <= 0.02)
    }

    @Test func emptyAndSilentInput() {
        #expect(SpeechActivityDetector().detect(Envelope(hop: 0.01, values: [])).spans.isEmpty)
        let silent = Envelope.rms(samples: [Float](repeating: 0, count: 16_000), sampleRate: 16_000)
        #expect(SpeechActivityDetector().detect(silent).spans.isEmpty)
    }
}

// MARK: - Boundary snapping

@Suite struct BoundarySnapperTests {
    @Test func earlyEndsSnapToBurstEnds() {
        let fx = BurstFixture.regular()
        let act = fx.activity
        // Two words per burst; the second ends 300 ms early (like SpeechTranscriber), the first starts 40 ms late.
        var words: [TranscriptWord] = []
        for (i, (a, b)) in fx.bursts.enumerated() {
            words.append(TranscriptWord(text: "w\(i)a", start: a + 0.04, end: a + 0.15))
            words.append(TranscriptWord(text: "w\(i)b", start: a + 0.18, end: b - 0.3))
        }
        let snapped = BoundarySnapper.snap(words, activity: act)
        #expect(snapped.count == words.count)
        for (i, (a, b)) in fx.bursts.enumerated() {
            let first = snapped[2 * i], second = snapped[2 * i + 1]
            #expect(abs(first.start - a) <= 0.02, "start \(first.start) vs \(a)")
            #expect(abs(second.end - b) <= 0.02, "end \(second.end) vs \(b)")
            // First word extends through voice but stops at the next word's start.
            #expect(first.end <= second.start + 1e-9)
        }
        for w in snapped { #expect(w.start <= w.end) }
        for (x, y) in zip(snapped, snapped.dropFirst()) {
            #expect(x.end <= y.start + 1e-9, "overlap \(x.text) \(y.text)")
            #expect(x.start <= y.start)
        }
    }

    @Test func wordInSilenceShrinks() {
        let fx = BurstFixture.regular()
        let act = fx.activity
        let (_, b) = fx.bursts[1]
        let w = TranscriptWord(text: "ghost", start: b + 0.2, end: b + 0.45)
        let out = BoundarySnapper.snap([w], activity: act)
        #expect(out.count == 1)
        #expect(out[0].start <= out[0].end)
        #expect(out[0].end - out[0].start < w.end - w.start)
        #expect(out[0].end - out[0].start <= 0.02 + 1e-9)
    }

    @Test func extensionIsCappedAndOrderIsSorted() {
        // A word whose end sits in a long voiced region extends at most maxExtendEnd.
        let fx = BurstFixture(bursts: [(0.5, 3.0)], duration: 4)
        let words = [TranscriptWord(text: "b", start: 1.5, end: 1.8), TranscriptWord(text: "a", start: 0.6, end: 0.8)]
        let out = BoundarySnapper.snap(words, activity: fx.activity)
        #expect(out.map(\.text) == ["a", "b"])
        #expect(abs(out[0].end - 1.4) < 0.011 || out[0].end <= 1.5) // 0.8 + 0.6 = 1.4
        #expect(abs(out[1].end - 2.4) < 0.011)
        #expect(abs(out[0].start - 0.5) <= 0.02) // 0.6 - 0.15 would be 0.45, but voice starts at 0.5
        #expect(out[1].start >= out[0].end)
    }
}

// MARK: - Fillers

@Suite struct FillerTests {
    @Test func lexicalFillers() {
        #expect(Fillers.isFiller("Um,"))
        #expect(Fillers.isFiller("Uh"))
        #expect(Fillers.isFiller("uhm."))
        #expect(Fillers.isFiller("Hmm"))
        #expect(Fillers.isFiller("mm"))
        #expect(Fillers.isFiller("erm"))
        #expect(Fillers.isFiller("Ummm..."))
        #expect(!Fillers.isFiller("umbrella"))
        #expect(!Fillers.isFiller("the"))
        #expect(!Fillers.isFiller(""))
        #expect(!Fillers.isFiller("..."))
        let marked = Fillers.markFillers([TranscriptWord(text: "Um,", start: 0, end: 0.2),
                                          TranscriptWord(text: "so", start: 0.3, end: 0.5)])
        #expect(marked.map(\.isFiller) == [true, false])
    }

    @Test func unwordedFindsVoicedBurstWithoutWord() {
        let fx = BurstFixture.regular()
        let act = fx.activity
        var words: [TranscriptWord] = []
        for (i, (a, b)) in fx.bursts.enumerated() where i != 2 {
            words.append(TranscriptWord(text: "w\(i)", start: a - 0.05, end: b + 0.05))
        }
        let found = Fillers.unworded(activity: act, words: words)
        #expect(found.count == 1)
        if let f = found.first {
            #expect(abs(f.start - fx.bursts[2].0) <= 0.02)
            #expect(abs(f.end - fx.bursts[2].1) <= 0.02)
        }
    }

    @Test func unwordedFindsLeadingFillerInsideSpan() {
        // One span [1.0, 3.0]; a word covers [1.4, 3.0] → [1.0, 1.4] is unworded; a short 0.1 s hole is ignored.
        let act = SpeechActivity(spans: [.init(start: 1.0, end: 3.0)], rms: Envelope(hop: 0.01, values: []),
                                 noiseFloor: -60, threshold: -50)
        let words = [TranscriptWord(text: "so", start: 1.4, end: 2.0), TranscriptWord(text: "yes", start: 2.1, end: 3.0)]
        let found = Fillers.unworded(activity: act, words: words)
        #expect(found == [.init(start: 1.0, end: 1.4)])
    }
}

// MARK: - Real fixture (optional)

enum FixtureLocator {
    static let directory: URL? = {
        var candidates: [URL] = []
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            candidates.append(dir.appendingPathComponent("Fixtures"))
            dir = dir.deletingLastPathComponent()
        }
        candidates.append(URL(fileURLWithPath: "/Users/yashjain/dev/Personal Projects/Clipper/Fixtures"))
        let fm = FileManager.default
        return candidates.first {
            fm.fileExists(atPath: $0.appendingPathComponent("speech_clean.wav").path)
                && fm.fileExists(atPath: $0.appendingPathComponent("speech_truth.json").path)
        }
    }()
}

private struct SpeechTruth: Decodable {
    struct Sentence: Decodable { var text: String; var start: Double; var end: Double }
    var duration: Double
    var sentences: [Sentence]
}

@Suite struct SpeechFixtureTests {
    @Test(.enabled(if: FixtureLocator.directory != nil, "Fixtures/speech_clean.wav not present"))
    func detectedSpansMatchSentenceBoundaries() async throws {
        let dir = try #require(FixtureLocator.directory)
        let truth = try JSONDecoder().decode(SpeechTruth.self,
                                             from: Data(contentsOf: dir.appendingPathComponent("speech_truth.json")))
        let samples = try await AudioReader.readMono(url: dir.appendingPathComponent("speech_clean.wav"), sampleRate: 16_000)
        #expect(abs(Double(samples.count) / 16_000 - truth.duration) < 0.05)

        let act = SpeechActivityDetector().detect(Envelope.rms(samples: samples, sampleRate: 16_000))
        #expect(!act.spans.isEmpty)
        let starts = act.spans.map(\.start), ends = act.spans.map(\.end)
        let startErr = truth.sentences.map { s in starts.map { abs($0 - s.start) }.min()! }
        let endErr = truth.sentences.map { s in ends.map { abs($0 - s.end) }.min()! }
        func median(_ v: [Double]) -> Double { let s = v.sorted(); return s[s.count / 2] }
        print("speech_clean: \(act.spans.count) spans, floor \(act.noiseFloor) dB, thr \(act.threshold) dB, "
              + "start err median \(Int(median(startErr) * 1000)) ms, end err median \(Int(median(endErr) * 1000)) ms")
        #expect(median(startErr) <= 0.06)
        #expect(median(endErr) <= 0.06)

        // A range read returns the right number of samples.
        let part = try await AudioReader.readMono(url: dir.appendingPathComponent("speech_clean.wav"),
                                                  sampleRate: 16_000, range: 1.0...3.0)
        #expect(abs(part.count - 32_000) <= 160)
    }
}
