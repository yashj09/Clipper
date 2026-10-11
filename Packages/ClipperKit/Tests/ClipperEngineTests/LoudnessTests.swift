import ClipperCore
import Foundation
import Testing
@testable import ClipperEngine

// MARK: - Signal helpers

/// Interleaved sine, identical in every channel. `amplitudeDB` is the peak amplitude in dBFS.
private func sine(frequency: Double, amplitudeDB: Double, seconds: Double, sampleRate: Double,
                  channels: Int = 2, phase: Double = 0) -> [Float] {
    let frames = Int(seconds * sampleRate)
    let amplitude = pow(10, amplitudeDB / 20)
    let w = 2 * Double.pi * frequency / sampleRate
    var out = [Float](repeating: 0, count: frames * channels)
    for n in 0..<frames {
        let v = Float(amplitude * sin(w * Double(n) + phase))
        for c in 0..<channels { out[n * channels + c] = v }
    }
    return out
}

/// Feeds the meter in odd-sized chunks to exercise the streaming paths.
private func measure(_ samples: [Float], sampleRate: Double, channels: Int = 2, chunkFrames: Int = 1013) -> LoudnessMeter {
    var meter = LoudnessMeter(sampleRate: sampleRate, channels: channels)
    samples.withUnsafeBufferPointer { all in
        var start = 0
        while start < all.count {
            let end = min(all.count, start + chunkFrames * channels)
            meter.process(interleaved: UnsafeBufferPointer(rebasing: all[start..<end]))
            start = end
        }
    }
    return meter
}

private func truePeak(_ samples: [Float], channels: Int) -> Double {
    var detector = TruePeakDetector(channels: channels)
    samples.withUnsafeBufferPointer { detector.process(interleaved: $0) }
    return detector.peakDBTP
}

/// Deterministic generator so noise tests are reproducible.
private struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) * 2 - 1 }
}

/// Pink-ish noise (Paul Kellet's economy filter), stereo with independent channels.
private func pinkNoise(seconds: Double, sampleRate: Double, seed: UInt64 = 42) -> [Float] {
    var rng = SplitMix64(state: seed)
    let frames = Int(seconds * sampleRate)
    var out = [Float](repeating: 0, count: frames * 2)
    for c in 0..<2 {
        var b0 = 0.0, b1 = 0.0, b2 = 0.0
        for n in 0..<frames {
            let white = rng.uniform()
            b0 = 0.99765 * b0 + white * 0.0990460
            b1 = 0.96300 * b1 + white * 0.2965164
            b2 = 0.57000 * b2 + white * 1.0526913
            out[n * 2 + c] = Float((b0 + b1 + b2 + white * 0.1848) * 0.1)
        }
    }
    return out
}

private func scaled(_ x: [Float], dB: Double) -> [Float] {
    let g = Float(pow(10, dB / 20))
    return x.map { $0 * g }
}

private func runLimiter(_ input: [Float], sampleRate: Double, channels: Int, ceiling: Double = -1,
                        chunkFrames: Int = 777) -> (output: [Float], latency: Int) {
    var limiter = TruePeakLimiter(sampleRate: sampleRate, channels: channels, ceilingDBTP: ceiling)
    var output: [Float] = []
    output.reserveCapacity(input.count + limiter.latencyFrames * channels)
    var start = 0
    while start < input.count {
        let end = min(input.count, start + chunkFrames * channels)
        var chunk = Array(input[start..<end])
        limiter.process(&chunk)
        output.append(contentsOf: chunk)
        start = end
    }
    output.append(contentsOf: limiter.flush())
    return (output, limiter.latencyFrames)
}

// MARK: - Tests

@Suite("Loudness")
struct LoudnessTests {
    @Test func kWeightingMatchesPublished48kCoefficients() {
        let c = KWeighting.coefficients(sampleRate: 48_000)
        let expected = [1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585,
                        1.0, -2.0, 1.0, -1.99004745483398, 0.99007225036621]
        for (a, b) in zip(c, expected) { #expect(abs(a - b) < 1e-8, "\(a) vs \(b)") }
    }

    @Test(arguments: [44_100.0, 48_000.0, 96_000.0])
    func ebu3341SineReadsItsLevel(sampleRate: Double) {
        for level in [-23.0, -33.0] {
            let meter = measure(sine(frequency: 1000, amplitudeDB: level, seconds: 20, sampleRate: sampleRate),
                                sampleRate: sampleRate)
            #expect(abs(meter.integratedLUFS - level) <= 0.1, "\(sampleRate) Hz, \(level): \(meter.integratedLUFS)")
            #expect(meter.loudnessRange < 0.1)
        }
    }

    @Test func planarInputMatchesInterleaved() {
        let x = sine(frequency: 1000, amplitudeDB: -23, seconds: 5, sampleRate: 48_000)
        var planar = [[Float]](repeating: [], count: 2)
        for c in 0..<2 { planar[c] = stride(from: c, to: x.count, by: 2).map { x[$0] } }
        var meter = LoudnessMeter(sampleRate: 48_000, channels: 2)
        meter.process(planar: planar)
        let reference = measure(x, sampleRate: 48_000)
        #expect(abs(meter.integratedLUFS - reference.integratedLUFS) < 1e-9)
        #expect(abs(meter.truePeakDBTP - reference.truePeakDBTP) < 1e-6)
    }

    @Test func relativeGateExcludesQuietParts() {
        let quiet = sine(frequency: 1000, amplitudeDB: -36, seconds: 10, sampleRate: 48_000)
        let loud = sine(frequency: 1000, amplitudeDB: -23, seconds: 60, sampleRate: 48_000)
        let meter = measure(quiet + loud + quiet, sampleRate: 48_000)
        #expect(abs(meter.integratedLUFS - -23) <= 0.1, "\(meter.integratedLUFS)")
    }

    @Test func silenceIsFloorNotNaN() {
        var meter = LoudnessMeter(sampleRate: 48_000, channels: 2)
        meter.process(interleaved: [Float](repeating: 0, count: 48_000 * 2 * 5))
        let r = meter.result()
        #expect(r.integrated <= -70 && !r.integrated.isNaN)
        #expect(r.truePeak <= -70 && !r.truePeak.isNaN)
        #expect(r.range == 0)
        #expect((try? JSONEncoder().encode(r)) != nil)

        let empty = LoudnessMeter(sampleRate: 48_000, channels: 1).result()
        #expect(empty.integrated <= -70 && empty.truePeak <= -70 && empty.range == 0)
    }

    @Test func lfeIsExcludedAndSurroundsWeighted() {
        // 5.1: a tone only in LFE reads as silence; a tone only in Ls reads 1.41x (≈ +1.5 dB) vs. L alone.
        let sr = 48_000.0
        let mono = sine(frequency: 1000, amplitudeDB: -20, seconds: 5, sampleRate: sr, channels: 1)
        func surround(onlyIn channel: Int) -> [Float] {
            var x = [Float](repeating: 0, count: mono.count * 6)
            for n in 0..<mono.count { x[n * 6 + channel] = mono[n] }
            return x
        }
        let lfe = measure(surround(onlyIn: 3), sampleRate: sr, channels: 6)
        let left = measure(surround(onlyIn: 0), sampleRate: sr, channels: 6)
        let ls = measure(surround(onlyIn: 4), sampleRate: sr, channels: 6)
        #expect(lfe.integratedLUFS <= -70)
        #expect(abs((ls.integratedLUFS - left.integratedLUFS) - 10 * log10(1.41)) < 0.01)
    }

    @Test func truePeakOfQuarterRateSineAt45Degrees() {
        // Samples are ±1 but the underlying sine peaks at √2 between them: +3.01 dBTP.
        let sr = 48_000.0
        let raw = sine(frequency: sr / 4, amplitudeDB: 0, seconds: 1, sampleRate: sr, channels: 1, phase: .pi / 4)
        let samplePeak = raw.map { abs($0) }.max()!
        let x = raw.map { $0 / samplePeak }
        let tp = truePeak(x, channels: 1)
        #expect(abs(tp - 3.01) <= 0.3, "\(tp)")
    }

    @Test func truePeakOfPlainSine() {
        let x = sine(frequency: 1000, amplitudeDB: -6, seconds: 1, sampleRate: 48_000)
        let tp = truePeak(x, channels: 2)
        #expect(abs(tp - -6) <= 0.2, "\(tp)")
        let meter = measure(x, sampleRate: 48_000)
        #expect(abs(meter.truePeakDBTP - tp) < 1e-9)
    }

    @Test func loudnessRangeOfTwoLevels() {
        let a = sine(frequency: 1000, amplitudeDB: -20, seconds: 20, sampleRate: 48_000)
        let b = sine(frequency: 1000, amplitudeDB: -30, seconds: 20, sampleRate: 48_000)
        let meter = measure(a + b, sampleRate: 48_000)
        #expect(abs(meter.loudnessRange - 10) <= 1, "\(meter.loudnessRange)")
    }

    @Test func limiterHoldsCeilingOnHotNoise() {
        let sr = 48_000.0
        let noise = pinkNoise(seconds: 10, sampleRate: sr)
        let hot = scaled(noise, dB: 6 - truePeak(noise, channels: 2))
        #expect(abs(truePeak(hot, channels: 2) - 6) < 0.01)
        let (out, _) = runLimiter(hot, sampleRate: sr, channels: 2)
        #expect(out.count == hot.count + TruePeakLimiter(sampleRate: sr, channels: 2).latencyFrames * 2)
        let tp = truePeak(out, channels: 2)
        #expect(tp <= -1 + 0.2, "limited noise true peak \(tp)")
        #expect(out.allSatisfy { $0.isFinite })
    }

    @Test(arguments: [44_100.0, 48_000.0, 96_000.0])
    func limiterHoldsCeilingOnHotSine(sampleRate: Double) {
        // Hot sines at several frequencies, including near-Nyquist content with large inter-sample peaks.
        for f in [100.0, 1000.0, 11_025.0, 17_000.0] {
            let raw = sine(frequency: f, amplitudeDB: 0, seconds: 2, sampleRate: sampleRate, phase: .pi / 4)
            let hot = scaled(raw, dB: 6 - truePeak(raw, channels: 2))
            let tp = truePeak(runLimiter(hot, sampleRate: sampleRate, channels: 2).output, channels: 2)
            #expect(tp <= -1 + 0.2, "\(f) Hz @ \(sampleRate): \(tp)")
        }
    }

    @Test func limiterHandlesTransientBursts() {
        // Quiet signal with sudden full-scale bursts: the gain has to drop within the lookahead.
        let sr = 48_000.0
        var x = sine(frequency: 440, amplitudeDB: -30, seconds: 3, sampleRate: sr)
        let burst = sine(frequency: 3000, amplitudeDB: 8, seconds: 0.02, sampleRate: sr)
        for start in [Int(0.5 * sr), Int(1.3 * sr), Int(1.31 * sr), Int(2.2 * sr)] {
            for i in 0..<burst.count { x[start * 2 + i] += burst[i] }
        }
        let (out, _) = runLimiter(x, sampleRate: sr, channels: 2, chunkFrames: 64)
        #expect(truePeak(out, channels: 2) <= -0.8)
    }

    @Test func limiterIsTransparentBelowCeiling() {
        let sr = 48_000.0
        let x = sine(frequency: 1000, amplitudeDB: -20, seconds: 2, sampleRate: sr)
        let (out, latency) = runLimiter(x, sampleRate: sr, channels: 2)
        #expect(latency > 0 && latency < Int(0.01 * sr))
        var maxErrorDB = 0.0
        for i in 0..<x.count where abs(x[i]) > 1e-3 {
            let y = out[i + latency * 2]
            maxErrorDB = max(maxErrorDB, abs(20 * log10(Double(y / x[i]))))
        }
        #expect(maxErrorDB < 0.01, "\(maxErrorDB) dB")
        // The leading latency is silence and nothing is lost at the end.
        #expect(out.prefix(latency * 2).allSatisfy { $0 == 0 })
        #expect(Array(out[(latency * 2)...]) == x)
    }

    @Test func normalizerGain() {
        let m = LoudnessInfo(integrated: -30, truePeak: -10, range: 5)
        #expect(LoudnessNormalizer.gain(measured: m, target: -14, ceiling: -1, limiterAvailable: true) == 16)
        #expect(LoudnessNormalizer.gain(measured: m, target: -14, ceiling: -1, limiterAvailable: false) == 9)
        // Turning down is never limited by the ceiling.
        let loud = LoudnessInfo(integrated: -8, truePeak: 0.5, range: 3)
        #expect(LoudnessNormalizer.gain(measured: loud, target: -14, ceiling: -1, limiterAvailable: false) == -6)
        // Hot peaks force a cut below the loudness target when there's no limiter.
        let peaky = LoudnessInfo(integrated: -16, truePeak: 1, range: 3)
        #expect(LoudnessNormalizer.gain(measured: peaky, target: -14, ceiling: -1, limiterAvailable: false) == -2)
        // Silence: leave it alone.
        let silent = LoudnessInfo(integrated: -120, truePeak: -120, range: 0)
        #expect(LoudnessNormalizer.gain(measured: silent, target: -14, ceiling: -1, limiterAvailable: false) == 0)
    }

    /// Wall-clock benchmark: only meaningful on an idle machine, so opt-in (CLIPPER_PERF_TESTS=1).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLIPPER_PERF_TESTS"] == "1")) func meterPerformanceTenMinutesStereo() {
        let sr = 48_000.0
        let chunk = sine(frequency: 997, amplitudeDB: -18, seconds: 1, sampleRate: sr)
        var meter = LoudnessMeter(sampleRate: sr, channels: 2)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            chunk.withUnsafeBufferPointer { buf in
                for _ in 0..<600 {
                    var start = 0
                    while start < buf.count {
                        let end = min(buf.count, start + 8192 * 2)
                        meter.process(interleaved: UnsafeBufferPointer(rebasing: buf[start..<end]))
                        start = end
                    }
                }
            }
        }
        print("LoudnessMeter: 10 min stereo 48 kHz in \(elapsed)")
        #expect(abs(meter.integratedLUFS - -18) < 0.2)
        #expect(elapsed < .seconds(5))
    }
}

// MARK: - ffmpeg cross-check

private let ffmpegPath = "/opt/homebrew/bin/ffmpeg"
private let hasFFmpeg = FileManager.default.isExecutableFile(atPath: ffmpegPath)

private func runFFmpeg(_ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: ffmpegPath)
    process.arguments = ["-hide_banner", "-nostats", "-y"] + arguments
    let pipe = Pipe()
    process.standardError = pipe
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// Parses the summary of `-af ebur128=peak=true`: (integrated LUFS, true peak dBTP).
private func ffmpegEBUR128(_ url: URL) throws -> (integrated: Double, truePeak: Double) {
    let log = try runFFmpeg(["-i", url.path, "-af", "ebur128=peak=true:framelog=quiet", "-f", "null", "-"])
    guard let summary = log.range(of: "Summary:") else { throw CocoaError(.fileReadCorruptFile) }
    var integrated = Double.nan, peak = Double.nan
    for line in log[summary.upperBound...].split(separator: "\n") {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, let value = Double(parts[1]) else { continue }
        if parts[0] == "I:" { integrated = value }
        if parts[0] == "Peak:" { peak = value }
    }
    return (integrated, peak)
}

@Suite("Loudness vs ffmpeg", .enabled(if: hasFFmpeg, "ffmpeg not installed at /opt/homebrew/bin/ffmpeg"))
struct LoudnessFFmpegTests {
    static let sources: [(name: String, filter: String, layout: String)] = [
        ("sine", "sine=f=440:d=10:sample_rate=48000,volume=-12dB", "stereo"),
        ("pink", "anoisesrc=color=pink:d=10:a=0.4:r=48000:seed=7", "stereo"),
        ("music-ish", "sine=f=220:d=12:sample_rate=44100,volume=-6dB,tremolo=f=2:d=0.9", "stereo"),
        ("surround", "anoisesrc=color=pink:d=10:a=0.3:r=48000:seed=3", "5.1(side)"),
    ]

    @Test(arguments: 0..<sources.count)
    func matchesFFmpegEBUR128(index: Int) async throws {
        let source = Self.sources[index]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clipper-loudness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("\(source.name).wav")
        var args = ["-f", "lavfi", "-i", source.filter]
        if source.layout == "stereo" {
            args += ["-ac", "2"]
        } else {
            // Different levels per channel so LFE exclusion and surround weights matter.
            args += ["-af", "pan=5.1(side)|FL=c0|FR=0.5*c0|FC=0.7*c0|LFE=c0|SL=0.8*c0|SR=0.3*c0"]
        }
        args += ["-c:a", "pcm_f32le", wav.path]
        _ = try runFFmpeg(args)
        #expect(FileManager.default.fileExists(atPath: wav.path))

        let reference = try ffmpegEBUR128(wav)
        let ours = try await AudioFileLoudness.measure(url: wav)
        print("\(source.name): ours I=\(ours.integrated) TP=\(ours.truePeak) LRA=\(ours.range) | ffmpeg I=\(reference.integrated) TP=\(reference.truePeak)")
        #expect(abs(ours.integrated - reference.integrated) <= 0.2, "\(source.name) integrated")
        #expect(abs(ours.truePeak - reference.truePeak) <= 0.3, "\(source.name) true peak")
    }

    @Test func measuresTenMinuteFileQuickly() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clipper-loudness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("long.m4a")
        _ = try runFFmpeg(["-f", "lavfi", "-i", "anoisesrc=color=pink:d=600:a=0.3:r=48000:seed=1", "-ac", "2",
                           "-c:a", "aac", "-b:a", "192k", file.path])
        let clock = ContinuousClock()
        var info: LoudnessInfo?
        let elapsed = try await clock.measure { info = try await AudioFileLoudness.measure(url: file) }
        print("AudioFileLoudness: 10 min stereo AAC in \(elapsed) -> \(String(describing: info))")
        #expect(info != nil)
    }

    @Test func fileWithoutAudioThrows() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clipper-loudness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("video.mov")
        _ = try runFFmpeg(["-f", "lavfi", "-i", "color=c=black:s=64x64:d=1", "-c:v", "mjpeg", file.path])
        await #expect(throws: AudioFileLoudness.MeasureError.self) {
            _ = try await AudioFileLoudness.measure(url: file)
        }
    }
}
