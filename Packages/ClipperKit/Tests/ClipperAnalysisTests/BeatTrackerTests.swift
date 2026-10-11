import ClipperAnalysis
import ClipperCore
import Foundation
import Testing

/// Synthetic click tracks with known beat times.
struct ClickTrack {
    var samples: [Float]
    var beats: [Double]
    var accented: [Double]

    /// - Parameters:
    ///   - accentEvery: if > 0, every Nth click (starting with the first) is louder and carries a kick.
    ///   - ampJitter: relative random amplitude variation per click.
    ///   - noiseDB: optional background noise level (dBFS RMS).
    init(bpm: Double, seconds: Double = 30, sampleRate: Double = 22_050, offset: Double = 0.5, kick: Bool = false,
         accentEvery: Int = 0, ampJitter: Float = 0, noiseDB: Float? = nil, seed: UInt64 = 1) {
        let n = Int(seconds * sampleRate)
        var x = noiseDB.map { Signal.noise(count: n, rmsDB: $0, seed: seed &+ 100) } ?? [Float](repeating: 0, count: n)
        var rng = SplitMix64(seed: seed)
        var beats: [Double] = [], accented: [Double] = []
        let period = 60 / bpm
        var k = 0
        while true {
            let t = offset + Double(k) * period
            if t > seconds - 0.2 { break }
            let isAccent = accentEvery > 0 && k % accentEvery == 0
            var amp: Float = isAccent ? 0.9 : (accentEvery > 0 ? 0.3 : 0.6)
            if ampJitter > 0 { amp *= 1 + Float.random(in: -ampJitter...ampJitter, using: &rng) }
            let start = Int(t * sampleRate)
            // 10 ms click: decaying noise + 2 kHz ping.
            let clickLen = Int(0.010 * sampleRate)
            for i in 0..<clickLen where start + i < n {
                let env = Float(exp(-Double(i) / (0.002 * sampleRate)))
                let ping = Float(sin(2 * .pi * 2000 * Double(i) / sampleRate))
                x[start + i] += amp * env * (0.5 * ping + 0.5 * Float.random(in: -1...1, using: &rng))
            }
            if kick || isAccent {
                let kickLen = Int(0.08 * sampleRate)
                for i in 0..<kickLen where start + i < n {
                    let env = Float(exp(-Double(i) / (0.02 * sampleRate)))
                    x[start + i] += amp * 0.8 * env * Float(sin(2 * .pi * 60 * Double(i) / sampleRate))
                }
            }
            beats.append(t)
            if isAccent { accented.append(t) }
            k += 1
        }
        samples = x
        self.beats = beats
        self.accented = accented
    }
}

/// Fraction of `truth` times that have a detected time within `tol`.
func hitRate(_ detected: [Double], _ truth: [Double], tol: Double = 0.03) -> Double {
    guard !truth.isEmpty else { return 0 }
    let hits = truth.filter { t in detected.contains { abs($0 - t) <= tol } }.count
    return Double(hits) / Double(truth.count)
}

func meanSignedError(_ detected: [Double], _ truth: [Double]) -> Double {
    let errs = truth.compactMap { t -> Double? in
        guard let d = detected.min(by: { abs($0 - t) < abs($1 - t) }), abs(d - t) < 0.1 else { return nil }
        return d - t
    }
    return errs.isEmpty ? .nan : errs.reduce(0, +) / Double(errs.count)
}

@Suite struct BeatTrackerTests {
    @Test(arguments: [120.0, 90.0, 128.0, 75.0])
    func clickTrackTempoAndBeats(bpm: Double) {
        let track = ClickTrack(bpm: bpm, kick: bpm == 128)
        let grid = BeatTracker().analyze(samples: track.samples, sampleRate: 22_050)
        let recall = hitRate(grid.beats, track.beats)
        let precision = hitRate(track.beats, grid.beats)
        print(String(format: "%.0f BPM → %.2f BPM, %d beats (truth %d), recall %.2f, precision %.2f, bias %.1f ms",
                     bpm, grid.bpm, grid.beats.count, track.beats.count, recall, precision,
                     meanSignedError(grid.beats, track.beats) * 1000))
        let extra = grid.beats.filter { d in !track.beats.contains { abs($0 - d) <= 0.03 } }
        if !extra.isEmpty {
            print("  unmatched beats: \(extra.map { String(format: "%.3f", $0) }), truth \(track.beats.first!)…\(track.beats.last!)")        }
        #expect(abs(grid.bpm - bpm) / bpm <= 0.015)
        #expect(recall >= 0.9)
        #expect(precision >= 0.9)
    }

    @Test func clickTrackWithAmplitudeJitterAndNoise() {
        let track = ClickTrack(bpm: 104, ampJitter: 0.1, noiseDB: -45, seed: 9)
        let grid = BeatTracker().analyze(samples: track.samples, sampleRate: 22_050)
        let recall = hitRate(grid.beats, track.beats)
        print(String(format: "jitter+noise 104 BPM → %.2f BPM, recall %.2f", grid.bpm, recall))
        #expect(abs(grid.bpm - 104) / 104 <= 0.015)
        #expect(recall >= 0.9)
        #expect(hitRate(track.beats, grid.beats) >= 0.9)
    }

    @Test func otherSampleRates() {
        for sr in [44_100.0, 48_000.0] {
            let track = ClickTrack(bpm: 110, seconds: 20, sampleRate: sr)
            let grid = BeatTracker().analyze(samples: track.samples, sampleRate: sr)
            print(String(format: "%.0f Hz: %.2f BPM, recall %.2f", sr, grid.bpm, hitRate(grid.beats, track.beats)))
            #expect(abs(grid.bpm - 110) / 110 <= 0.015)
            #expect(hitRate(grid.beats, track.beats) >= 0.9)
        }
    }

    @Test func downbeatsFollowAccents() {
        let track = ClickTrack(bpm: 120, offset: 1.0, accentEvery: 4)
        let grid = BeatTracker().analyze(samples: track.samples, sampleRate: 22_050)
        #expect(abs(grid.bpm - 120) / 120 <= 0.015)
        #expect(!grid.downbeats.isEmpty)
        let ok = grid.downbeats.filter { d in track.accented.contains { abs($0 - d) <= 0.03 } }.count
        print("downbeats \(grid.downbeats.count), on accents \(ok), accents \(track.accented.count)")
        #expect(Double(ok) / Double(grid.downbeats.count) >= 0.9)
        #expect(hitRate(grid.downbeats, track.accented) >= 0.9)
    }

    @Test func downbeatPhaseNotZero() {
        // Prepend one unaccented beat so the first detected beat is not a downbeat.
        let sr = 22_050.0
        let track = ClickTrack(bpm: 100, offset: 0.6, accentEvery: 4)
        let shift = Int(0.6 * sr)
        var x = [Float](repeating: 0, count: shift) + track.samples
        // An extra plain click one beat before the first accent (at 0.6 + 0.6 - 0.6 = 0.6 s).
        let start = Int(0.6 * sr)
        for i in 0..<Int(0.01 * sr) { x[start + i] += 0.3 * Float(exp(-Double(i) / (0.002 * sr))) }
        let accents = track.accented.map { $0 + 0.6 }
        let grid = BeatTracker().analyze(samples: x, sampleRate: sr)
        #expect(hitRate(grid.downbeats, accents) >= 0.9)
        #expect(grid.downbeats.allSatisfy { d in accents.contains { abs($0 - d) <= 0.03 } })
    }

    @Test func silenceGivesEmptyGrid() {
        let grid = BeatTracker().analyze(samples: [Float](repeating: 0, count: 22_050 * 5), sampleRate: 22_050)
        #expect(grid.beats.isEmpty)
        #expect(BeatTracker().analyze(samples: [], sampleRate: 22_050).beats.isEmpty)
    }

    @Test func energyIsNormalized() {
        #expect(BeatTracker.energy(samples: []) == 0)
        #expect(BeatTracker.energy(samples: [Float](repeating: 0, count: 10_000)) == 0)
        let loud = Signal.sine(freq: 440, amplitude: 1, seconds: 1, sampleRate: 22_050)
        let quiet = Signal.sine(freq: 440, amplitude: 0.01, seconds: 1, sampleRate: 22_050)
        let el = BeatTracker.energy(samples: loud), eq = BeatTracker.energy(samples: quiet)
        #expect(el > 0.9 && el <= 1)
        #expect(eq > 0 && eq < el)
    }

    /// Wall-clock benchmark: only meaningful on an idle machine, so opt-in (CLIPPER_PERF_TESTS=1).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLIPPER_PERF_TESTS"] == "1")) func threeMinutesIsFast() {
        let track = ClickTrack(bpm: 124, seconds: 180, kick: true, ampJitter: 0.1, noiseDB: -40)
        let tracker = BeatTracker()
        let clock = ContinuousClock()
        let start = clock.now
        let grid = tracker.analyze(samples: track.samples, sampleRate: 22_050)
        let elapsed = clock.now - start
        print("BeatTracker, 3 min @ 22.05 kHz: \(elapsed), \(grid.bpm) BPM, recall \(hitRate(grid.beats, track.beats)), "
              + "precision \(hitRate(track.beats, grid.beats)), beats \(grid.beats.count)/\(track.beats.count), "
              + "bias \(meanSignedError(grid.beats, track.beats) * 1000) ms")
        #expect(abs(grid.bpm - 124) / 124 <= 0.015)
        #expect(hitRate(grid.beats, track.beats) >= 0.9)
        // 0.5 s target is for optimized builds; debug test builds get headroom.
        #expect(elapsed < .seconds(2))
    }
}
