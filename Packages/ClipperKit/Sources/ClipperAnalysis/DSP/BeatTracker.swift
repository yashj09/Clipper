import Accelerate
import ClipperCore
import Foundation

/// Tempo and beat tracking for music (librosa-style pipeline, Ellis 2007 dynamic programming).
///
/// 1. Onset strength: log-power mel spectrogram (Hann 2048 / hop 512 at 22.05 kHz, scaled to other rates,
///    80 dB dynamic range), half-wave rectified first difference averaged over bands (spectral flux).
/// 2. Tempo: autocorrelation of the mean-removed onset envelope, lightly smoothed, sampled on a 0.25 BPM grid in
///    `minBPM...maxBPM` and weighted by a log-normal prior centred at `startBPM` (σ = `priorOctaves` octaves). The prior
///    resolves octave ambiguity: a pulse train has equal autocorrelation at P, 2P, 3P…, and the prior prefers the
///    candidate nearest 120 BPM, i.e. the beat rather than the bar or half-bar.
/// 3. Beats: dynamic programming over the onset envelope with the estimated period (tightness 100), last beat from the
///    cumulative score, weak leading/trailing beats trimmed, each beat refined to the sub-frame onset peak.
/// 4. Reported BPM: least-squares fit of beat times against beat index (falls back to the autocorrelation tempo).
/// 5. Downbeats: every 4th beat, phase chosen by the highest mean onset strength.
public struct BeatTracker: Sendable {
    public var minBPM: Double = 60
    public var maxBPM: Double = 200
    /// Centre of the log-normal tempo prior.
    public var startBPM: Double = 120
    /// Standard deviation of the tempo prior, in octaves.
    public var priorOctaves: Double = 1.0
    /// How strongly the DP sticks to the estimated period (librosa default 100).
    public var tightness: Double = 100
    public var beatsPerBar: Int = 4

    public init() {}

    /// Tempo + beat times (seconds) for music. Returns `BeatGrid(bpm: 0, beats: [])` for silence or too-short input.
    public func analyze(samples: [Float], sampleRate: Double) -> BeatGrid {
        guard sampleRate > 0 else { return BeatGrid(bpm: 0, beats: []) }
        let onset = OnsetStrength(samples: samples, sampleRate: sampleRate)
        let env = onset.values
        guard env.count > 16, env.contains(where: { $0 > 0 }) else { return BeatGrid(bpm: 0, beats: []) }

        guard let tempo = estimateTempo(env, frameRate: onset.frameRate) else { return BeatGrid(bpm: 0, beats: []) }
        let period = 60 * onset.frameRate / tempo
        let frames = trackBeats(env, period: period)
        guard !frames.isEmpty else { return BeatGrid(bpm: tempo, beats: []) }

        let refined = frames.map { Self.refinePeak(env, near: $0) }
        let beats = refined.map { onset.time(ofFrame: $0) }
        let bpm = Self.fitBPM(beats) ?? tempo

        // Downbeats: phase with the highest mean onset strength.
        var downbeats: [Double] = []
        let bar = max(1, beatsPerBar)
        if beats.count >= bar {
            let strength = frames.map { f in env[max(0, f - 1)...min(env.count - 1, f + 1)].max() ?? 0 }
            var bestPhase = 0
            var bestMean = -Float.infinity
            for p in 0..<bar {
                let idx = stride(from: p, to: beats.count, by: bar)
                let vals = idx.map { strength[$0] }
                let mean = vals.reduce(0, +) / Float(max(1, vals.count))
                if mean > bestMean { bestMean = mean; bestPhase = p }
            }
            downbeats = stride(from: bestPhase, to: beats.count, by: bar).map { beats[$0] }
        } else if let first = beats.first {
            downbeats = [first]
        }
        return BeatGrid(bpm: bpm, beats: beats, downbeats: downbeats)
    }

    /// Mean normalized energy 0…1 (useful for matching music to pacing): the RMS level of ~46 ms frames
    /// (2048 samples) mapped linearly from -60 dBFS → 0 to 0 dBFS → 1, averaged over frames.
    public static func energy(samples: [Float]) -> Double {
        let k = 2048
        guard !samples.isEmpty else { return 0 }
        let n = max(1, samples.count / k)
        var total = 0.0
        samples.withUnsafeBufferPointer { src in
            for i in 0..<n {
                let len = min(k, samples.count - i * k)
                var ms: Float = 0
                vDSP_measqv(src.baseAddress! + i * k, 1, &ms, vDSP_Length(len))
                let db = 10 * log10(Double(max(ms, 1e-12)))
                total += min(1, max(0, (db + 60) / 60))
            }
        }
        return total / Double(n)
    }

    // MARK: - Tempo

    /// Prior-weighted autocorrelation tempo in BPM, or nil if the envelope has no periodicity.
    func estimateTempo(_ env: [Float], frameRate: Double) -> Double? {
        let n = env.count
        let maxLagF = 60 * frameRate / minBPM
        let maxLag = min(n - 2, Int(maxLagF.rounded(.up)) + 4)
        guard maxLag > 2 else { return nil }
        var mean: Float = 0
        vDSP_meanv(env, 1, &mean, vDSP_Length(n))
        let centered = env.map { $0 - mean }

        var ac = [Double](repeating: 0, count: maxLag + 1)
        centered.withUnsafeBufferPointer { p in
            for lag in 0...maxLag {
                var dot: Float = 0
                vDSP_dotpr(p.baseAddress!, 1, p.baseAddress! + lag, 1, &dot, vDSP_Length(n - lag))
                ac[lag] = Double(dot) / Double(n - lag)
            }
        }
        // Smooth with a Gaussian (σ = 1 frame) so pulse trains with fractional periods give one peak at the true lag.
        let radius = 3
        let kernel = (-radius...radius).map { exp(-0.5 * Double($0 * $0)) }
        var smooth = [Double](repeating: 0, count: ac.count)
        for i in 0..<ac.count {
            var s = 0.0, w = 0.0
            for (j, kv) in kernel.enumerated() {
                let idx = i + j - radius
                if idx >= 0 && idx < ac.count { s += ac[idx] * kv; w += kv }
            }
            smooth[i] = s / w
        }

        var best: Double?
        var bestScore = 0.0
        var bpm = minBPM
        while bpm <= maxBPM + 1e-9 {
            let lag = 60 * frameRate / bpm
            let i = Int(lag)
            if i + 1 < smooth.count {
                let frac = lag - Double(i)
                let value = smooth[i] * (1 - frac) + smooth[i + 1] * frac
                let z = log2(bpm / startBPM) / priorOctaves
                let score = value * exp(-0.5 * z * z)
                if score > bestScore { bestScore = score; best = bpm }
            }
            bpm += 0.25
        }
        return best
    }

    // MARK: - Dynamic programming beat tracker (Ellis 2007)

    /// Beat frame indices.
    func trackBeats(_ env: [Float], period: Double) -> [Int] {
        let n = env.count
        guard period >= 2, n > Int(period) else { return [] }

        // Normalise by standard deviation (ddof = 1).
        var mean: Float = 0, sumSq: Float = 0
        vDSP_meanv(env, 1, &mean, vDSP_Length(n))
        var sd = [Float](repeating: 0, count: n)
        var negMean = -mean
        vDSP_vsadd(env, 1, &negMean, &sd, 1, vDSP_Length(n))
        vDSP_svesq(sd, 1, &sumSq, vDSP_Length(n))
        let std = (Double(sumSq) / Double(max(1, n - 1))).squareRoot()
        guard std > 0 else { return [] }
        let norm = env.map { Double($0) / std }

        // Local score: onset envelope convolved with a narrow Gaussian (σ = period / 32), 'same' mode.
        let half = max(1, Int(period.rounded()))
        let win = (-half...half).map { exp(-0.5 * pow(Double($0) * 32 / period, 2)) }
        var local = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var s = 0.0
            for (j, w) in win.enumerated() where w > 1e-6 {
                let idx = i + j - half
                if idx >= 0 && idx < n { s += norm[idx] * w }
            }
            local[i] = s
        }

        // DP: previous beat searched in [i - 2P, i - P/2], cost -tightness · log(Δ/P)².
        let minD = max(1, Int((period / 2).rounded()))
        let maxD = max(minD, Int((2 * period).rounded()))
        let tx = (0...maxD).map { d -> Double in
            d < minD ? -.infinity : -tightness * pow(log(Double(d) / period), 2)
        }
        let maxLocal = local.max() ?? 0
        let firstThresh = 0.01 * maxLocal
        // Frames before the first real onset cannot be a predecessor, and a beat may start a new chain at no cost
        // (otherwise the first onset, having no in-range predecessor, is penalised and the chain starts in silence).
        var cum = [Double](repeating: 0, count: n)
        var back = [Int](repeating: -1, count: n)
        var firstOnset = n
        for i in 0..<n where local[i] >= firstThresh { firstOnset = i; break }
        for i in firstOnset..<n {
            var best = 0.0
            var bestZ = -1
            let lo = max(firstOnset, i - maxD)
            let hi = i - minD
            if hi >= lo {
                for z in lo...hi {
                    let c = cum[z] + tx[i - z]
                    if c > best { best = c; bestZ = z }
                }
            }
            cum[i] = local[i] + best
            back[i] = bestZ
        }

        // Last beat: last local maximum of the cumulative score above half the median of all local maxima.
        var maxima: [Int] = []
        for i in 1..<(n - 1) where cum[i] > cum[i - 1] && cum[i] >= cum[i + 1] { maxima.append(i) }
        guard !maxima.isEmpty else { return [] }
        let sortedMax = maxima.map { cum[$0] }.sorted()
        let median = sortedMax[sortedMax.count / 2]
        guard let last = maxima.last(where: { cum[$0] >= 0.5 * median }) else { return [] }

        var beats: [Int] = []
        var b = last
        while b >= 0 { beats.append(b); b = back[b] }
        beats.reverse()
        return Self.trim(beats, local: local)
    }

    /// Drops weak leading/trailing beats (librosa `__trim_beats`): smooth the local score at the beats with a short
    /// window ('same' mode, not edge-normalised, so an edge beat in silence falls below half the RMS while an edge beat
    /// on a real onset stays above it), then trim beats at either end at or below 0.5 × RMS.
    static func trim(_ beats: [Int], local: [Double]) -> [Int] {
        guard beats.count > 2 else { return beats }
        let w: [Double] = [0.25, 0.75, 1, 0.75, 0.25]
        let vals = beats.map { local[$0] }
        var smooth = [Double](repeating: 0, count: vals.count)
        for i in 0..<vals.count {
            var s = 0.0
            for j in 0..<w.count {
                let idx = i + j - 2
                if idx >= 0 && idx < vals.count { s += vals[idx] * w[j] }
            }
            smooth[i] = s
        }
        let rms = (smooth.map { $0 * $0 }.reduce(0, +) / Double(smooth.count)).squareRoot()
        let threshold = 0.5 * rms
        guard let first = smooth.firstIndex(where: { $0 > threshold }),
              let lastIdx = smooth.lastIndex(where: { $0 > threshold }) else { return [] }
        return Array(beats[first...lastIdx])
    }

    /// Sub-frame position of the onset peak within ±1 frame of `frame` (parabolic interpolation).
    static func refinePeak(_ env: [Float], near frame: Int) -> Double {
        let n = env.count
        var p = frame
        for c in [frame - 1, frame + 1] where c >= 0 && c < n && env[c] > env[p] { p = c }
        guard p > 0, p < n - 1 else { return Double(p) }
        let a = Double(env[p - 1]), b = Double(env[p]), c = Double(env[p + 1])
        let denom = a - 2 * b + c
        guard denom < 0 else { return Double(p) }
        let delta = 0.5 * (a - c) / denom
        return Double(p) + max(-0.5, min(0.5, delta))
    }

    /// BPM from a least-squares fit of beat time against beat index. Indices advance by each interval measured in
    /// median intervals (≥ 1), so a skipped beat does not skew the slope and small median errors do not accumulate.
    static func fitBPM(_ beats: [Double]) -> Double? {
        guard beats.count >= 4 else { return nil }
        let ibis = zip(beats.dropFirst(), beats).map { $0 - $1 }
        let med = ibis.sorted()[ibis.count / 2]
        guard med > 0 else { return nil }
        var ks = [0.0]
        for d in ibis { ks.append(ks.last! + max(1, (d / med).rounded())) }
        let mk = ks.reduce(0, +) / Double(ks.count)
        let mt = beats.reduce(0, +) / Double(beats.count)
        var num = 0.0, den = 0.0
        for (k, t) in zip(ks, beats) { num += (k - mk) * (t - mt); den += (k - mk) * (k - mk) }
        guard den > 0, num > 0 else { return nil }
        return 60 / (num / den)
    }
}

// MARK: - Onset strength

/// Spectral-flux onset envelope (log-power mel bands, half-wave rectified first difference, mean over bands).
struct OnsetStrength {
    var values: [Float]
    var hop: Int
    var sampleRate: Double
    var frameRate: Double { sampleRate / Double(hop) }

    /// Onset frames are centred STFT frames; a sharp attack peaks the flux in the first frame whose window catches
    /// most of it, which lies slightly *before* the attack. This constant (in hops) compensates; calibrated on click
    /// tracks.
    static let latencyHops = 1.2

    func time(ofFrame f: Double) -> Double { max(0, (f + Self.latencyHops) * Double(hop) / sampleRate) }

    init(samples: [Float], sampleRate: Double, melBands: Int = 64, topDB: Float = 80) {
        self.sampleRate = sampleRate
        let log2n = max(8, Int(log2(2048 * sampleRate / 22050).rounded()))
        let n = 1 << log2n
        let hop = n / 4
        self.hop = hop
        let half = n / 2
        guard samples.count >= hop else { values = []; return }
        let frames = samples.count / hop + 1

        var padded = [Float](repeating: 0, count: samples.count + n)
        padded.withUnsafeMutableBufferPointer { dst in
            samples.withUnsafeBufferPointer { src in
                (dst.baseAddress! + half).update(from: src.baseAddress!, count: samples.count)
            }
        }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        let bank = MelFilterbank(fftSize: n, sampleRate: sampleRate, bands: melBands,
                                 fMax: min(sampleRate / 2, 11025))
        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else { values = []; return }
        defer { vDSP_destroy_fftsetup(setup) }

        var mel = [Float](repeating: 0, count: frames * melBands)
        var windowed = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: half)
        var im = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half + 1)

        padded.withUnsafeBufferPointer { sig in
            window.withUnsafeBufferPointer { win in
                windowed.withUnsafeMutableBufferPointer { wbuf in
                    re.withUnsafeMutableBufferPointer { rp in
                        im.withUnsafeMutableBufferPointer { ip in
                            power.withUnsafeMutableBufferPointer { pw in
                                mel.withUnsafeMutableBufferPointer { melp in
                                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                                    for f in 0..<frames {
                                        vDSP_vmul(sig.baseAddress! + f * hop, 1, win.baseAddress!, 1,
                                                  wbuf.baseAddress!, 1, vDSP_Length(n))
                                        wbuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                                        }
                                        vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2n), FFTDirection(FFT_FORWARD))
                                        let nyq = ip[0], dc = rp[0]
                                        vDSP_zvmags(&split, 1, pw.baseAddress!, 1, vDSP_Length(half))
                                        pw[0] = dc * dc
                                        pw[half] = nyq * nyq
                                        bank.apply(pw.baseAddress!, into: melp.baseAddress! + f * melBands)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Power → dB with an 80 dB dynamic range below the global maximum.
        let count = mel.count
        mel.withUnsafeMutableBufferPointer { m in
            let p = m.baseAddress!
            var tiny: Float = 1e-10
            vDSP_vthr(p, 1, &tiny, p, 1, vDSP_Length(count))
            var c32 = Int32(count)
            vvlog10f(p, p, &c32)
            var ten: Float = 10
            vDSP_vsmul(p, 1, &ten, p, 1, vDSP_Length(count))
            var mx: Float = 0
            vDSP_maxv(p, 1, &mx, vDSP_Length(count))
            var floor = mx - topDB
            vDSP_vthr(p, 1, &floor, p, 1, vDSP_Length(count))
        }

        // Spectral flux: mean over bands of max(0, S[t] - S[t-1]).
        var env = [Float](repeating: 0, count: frames)
        if frames > 1 {
            let dcount = (frames - 1) * melBands
            var diff = [Float](repeating: 0, count: dcount)
            mel.withUnsafeBufferPointer { m in
                diff.withUnsafeMutableBufferPointer { d in
                    vDSP_vsub(m.baseAddress!, 1, m.baseAddress! + melBands, 1, d.baseAddress!, 1, vDSP_Length(dcount))
                    var zero: Float = 0
                    vDSP_vthres(d.baseAddress!, 1, &zero, d.baseAddress!, 1, vDSP_Length(dcount))
                    for f in 1..<frames {
                        var mean: Float = 0
                        vDSP_meanv(d.baseAddress! + (f - 1) * melBands, 1, &mean, vDSP_Length(melBands))
                        env[f] = mean
                    }
                }
            }
        }
        values = env
    }
}

/// Triangular mel filterbank (HTK mel scale) applied to a power spectrum of `fftSize/2 + 1` bins.
struct MelFilterbank {
    private var starts: [Int] = []
    private var weights: [[Float]] = []

    init(fftSize: Int, sampleRate: Double, bands: Int, fMin: Double = 0, fMax: Double) {
        func mel(_ f: Double) -> Double { 2595 * log10(1 + f / 700) }
        func hz(_ m: Double) -> Double { 700 * (pow(10, m / 2595) - 1) }
        let bins = fftSize / 2 + 1
        let binHz = sampleRate / Double(fftSize)
        let lo = mel(fMin), hi = mel(fMax)
        let edges = (0...(bands + 1)).map { hz(lo + (hi - lo) * Double($0) / Double(bands + 1)) }
        for b in 0..<bands {
            let l = edges[b], c = edges[b + 1], r = edges[b + 2]
            var first = -1
            var w: [Float] = []
            for k in 0..<bins {
                let f = Double(k) * binHz
                guard f > l && f < r else { continue }
                let v = f <= c ? (f - l) / (c - l) : (r - f) / (r - c)
                if first < 0 { first = k }
                w.append(Float(v))
            }
            if first < 0 { // narrower than one bin: take the nearest bin
                first = min(bins - 1, Int((c / binHz).rounded()))
                w = [1]
            }
            starts.append(first)
            weights.append(w)
        }
    }

    func apply(_ power: UnsafePointer<Float>, into out: UnsafeMutablePointer<Float>) {
        for b in 0..<starts.count {
            weights[b].withUnsafeBufferPointer { w in
                vDSP_dotpr(power + starts[b], 1, w.baseAddress!, 1, out + b, vDSP_Length(w.count))
            }
        }
    }
}
