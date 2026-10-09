import Accelerate
import ClipperCore
import Foundation

/// BS.1770-4 K-weighting: a high-shelf "pre-filter" followed by the RLB high-pass, both as biquads.
///
/// The standard publishes coefficients for 48 kHz only. Here each stage is described by its analog
/// prototype (centre frequency, Q and, for the shelf, gain), fitted so that the bilinear transform at
/// 48 kHz reproduces the published coefficients, and re-discretised at the actual sample rate.
/// (Same approach as libebur128.)
enum KWeighting {
    /// Five coefficients per section, `[b0, b1, b2, a1, a2]` with `a0` normalised to 1, two sections.
    static func coefficients(sampleRate fs: Double) -> [Double] {
        // Stage 1: high shelf, +4 dB above ~1.7 kHz (models the acoustic effect of the head).
        let f0 = 1681.974450955533
        let gainDB = 3.999843853973347
        let q0 = 0.7071752369554196
        let k0 = tan(Double.pi * f0 / fs)
        let vh = pow(10, gainDB / 20)
        let vb = pow(vh, 0.4996667741545416)
        let n0 = 1 + k0 / q0 + k0 * k0
        let shelf = [
            (vh + vb * k0 / q0 + k0 * k0) / n0,
            2 * (k0 * k0 - vh) / n0,
            (vh - vb * k0 / q0 + k0 * k0) / n0,
            2 * (k0 * k0 - 1) / n0,
            (1 - k0 / q0 + k0 * k0) / n0,
        ]
        // Stage 2: RLB weighting, a 2nd-order high-pass at ~38 Hz. The numerator is [1, -2, 1] as published.
        let f1 = 38.13547087602444
        let q1 = 0.5003270373238773
        let k1 = tan(Double.pi * f1 / fs)
        let n1 = 1 + k1 / q1 + k1 * k1
        let highPass = [1, -2, 1, 2 * (k1 * k1 - 1) / n1, (1 - k1 / q1 + k1 * k1) / n1]
        return shelf + highPass
    }
}

/// Owns a vDSP biquad setup. The setup is immutable after creation (filter state lives in caller-owned
/// delay buffers), so sharing it between copies of a meter, or across threads, is safe.
final class BiquadSetup: @unchecked Sendable {
    let setup: vDSP_biquad_SetupD
    let sections: Int

    init(coefficients: [Double]) {
        precondition(coefficients.count % 5 == 0 && !coefficients.isEmpty)
        sections = coefficients.count / 5
        guard let s = vDSP_biquad_CreateSetupD(coefficients, vDSP_Length(sections)) else {
            fatalError("vDSP_biquad_CreateSetupD failed")
        }
        setup = s
    }

    deinit { vDSP_biquad_DestroySetupD(setup) }

    var delayLength: Int { 2 * sections + 2 }
}

/// Streaming ITU-R BS.1770-4 / EBU R128 loudness meter.
///
/// - Integrated loudness: 400 ms blocks with 75 % overlap (100 ms hop), absolute gate -70 LUFS,
///   relative gate -10 LU.
/// - Loudness range: EBU Tech 3342, 3 s short-term windows every 100 ms, absolute gate -70 LUFS,
///   relative gate -20 LU, 10th to 95th percentile.
/// - True peak: 4x oversampled (BS.1770-4 Annex 2), max over channels.
///
/// K-weighting runs in double precision via vDSP biquads with coefficients derived for the actual sample
/// rate. Only complete blocks count, so input shorter than 400 ms reads as silence.
public struct LoudnessMeter: Sendable {
    /// Value reported for silence (instead of -inf, which JSON can't encode).
    public static let silenceFloor = -120.0
    static let absoluteGateLUFS = -70.0

    public let sampleRate: Double
    public let channels: Int
    /// BS.1770 channel weights `G_i` (0 excludes a channel, e.g. LFE).
    public let channelWeights: [Double]

    private let biquad: BiquadSetup
    private var delays: [[Double]]
    private let subBlockFrames: Int        // 100 ms
    private var framesInSubBlock = 0
    private var subBlockSum = 0.0          // weighted sum of squares of the current 100 ms sub-block
    private var recentSubBlocks: [Double] = []  // last 30 completed sub-block sums
    private var blockEnergies: [Double] = []    // mean-square (weighted) of each 400 ms block
    private var shortTermEnergies: [Double] = [] // mean-square (weighted) of each 3 s window
    private var truePeak: TruePeakDetector

    public init(sampleRate: Double, channels: Int) {
        self.init(sampleRate: sampleRate, channels: channels, channelWeights: Self.defaultWeights(channels: channels))
    }

    public init(sampleRate: Double, channels: Int, channelWeights: [Double]) {
        precondition(sampleRate > 0, "sample rate must be positive")
        precondition(channels > 0 && channelWeights.count == channels, "need one weight per channel")
        self.sampleRate = sampleRate
        self.channels = channels
        self.channelWeights = channelWeights
        biquad = BiquadSetup(coefficients: KWeighting.coefficients(sampleRate: sampleRate))
        delays = Array(repeating: Array(repeating: 0, count: biquad.delayLength), count: channels)
        subBlockFrames = max(1, Int((sampleRate / 10).rounded()))
        truePeak = TruePeakDetector(channels: channels)
    }

    /// Default weights by channel count, assuming these orders:
    /// 1 mono · 2 L R · 3 L R C · 4 L R Ls Rs · 5 L R C Ls Rs · 6 L R C LFE Ls Rs ·
    /// 7 L R C LFE Ls Rs Cs · 8 L R C LFE Ls Rs Rls Rrs. Other counts weigh every channel 1.0.
    public static func defaultWeights(channels: Int) -> [Double] {
        let s = 1.41
        switch channels {
        case 1: return [1]
        case 2: return [1, 1]
        case 3: return [1, 1, 1]
        case 4: return [1, 1, s, s]
        case 5: return [1, 1, 1, s, s]
        case 6: return [1, 1, 1, 0, s, s]
        case 7: return [1, 1, 1, 0, s, s, s]
        case 8: return [1, 1, 1, 0, s, s, s, s]
        default: return Array(repeating: 1, count: max(channels, 0))
        }
    }

    // MARK: Input

    /// Interleaved samples; the frame count is `count / channels`.
    public mutating func process(interleaved: UnsafeBufferPointer<Float>) {
        guard let base = interleaved.baseAddress else { return }
        let frames = interleaved.count / channels
        guard frames > 0 else { return }
        let stride = channels
        ingest(frames: frames) { ch, dst in
            vDSP_vspdp(base + ch, vDSP_Stride(stride), dst, 1, vDSP_Length(frames))
        }
        truePeak.process(interleaved: UnsafeBufferPointer(start: base, count: frames * channels))
    }

    public mutating func process(interleaved: [Float]) {
        interleaved.withUnsafeBufferPointer { process(interleaved: $0) }
    }

    /// One array per channel (all the same length; extra samples in longer channels are ignored).
    public mutating func process(planar: [[Float]]) {
        precondition(planar.count == channels, "planar channel count mismatch")
        let frames = planar.map(\.count).min() ?? 0
        guard frames > 0 else { return }
        ingest(frames: frames) { ch, dst in
            planar[ch].withUnsafeBufferPointer { vDSP_vspdp($0.baseAddress!, 1, dst, 1, vDSP_Length(frames)) }
        }
        truePeak.process(planar: planar.map { $0.count == frames ? $0 : Array($0.prefix(frames)) })
    }

    // MARK: Results

    /// Gated integrated loudness in LUFS, or `silenceFloor` if no block passes the absolute gate.
    public var integratedLUFS: Double {
        let absolute = Self.energy(lufs: Self.absoluteGateLUFS)
        guard let ungated = Self.mean(blockEnergies, above: absolute) else { return Self.silenceFloor }
        let relative = ungated * pow(10, -10.0 / 10)
        guard let gated = Self.mean(blockEnergies, above: max(absolute, relative)) else { return Self.silenceFloor }
        return max(Self.lufs(energy: gated), Self.silenceFloor)
    }

    /// EBU Tech 3342 loudness range in LU (0 if there's not enough gated short-term data).
    public var loudnessRange: Double {
        let absolute = Self.energy(lufs: Self.absoluteGateLUFS)
        guard let ungated = Self.mean(shortTermEnergies, above: absolute) else { return 0 }
        let threshold = max(absolute, ungated * pow(10, -20.0 / 10))
        let values = shortTermEnergies.filter { $0 > threshold }.sorted()
        guard values.count > 1 else { return 0 }
        func percentile(_ p: Double) -> Double {
            Self.lufs(energy: values[Int((Double(values.count - 1) * p).rounded())])
        }
        return max(0, percentile(0.95) - percentile(0.10))
    }

    /// Max true peak over all channels in dBTP (`silenceFloor` for silence).
    public var truePeakDBTP: Double { truePeak.peakDBTP }

    /// Sample (not oversampled) peak over all channels in dBFS.
    public var samplePeakDBFS: Double { truePeak.samplePeakDBFS }

    /// Loudness of the most recent 400 ms block (momentary), or `silenceFloor`.
    public var momentaryLUFS: Double {
        blockEnergies.last.map { max(Self.lufs(energy: $0), Self.silenceFloor) } ?? Self.silenceFloor
    }

    /// Loudness of the most recent 3 s window (short-term), or `silenceFloor`.
    public var shortTermLUFS: Double {
        shortTermEnergies.last.map { max(Self.lufs(energy: $0), Self.silenceFloor) } ?? Self.silenceFloor
    }

    public func result() -> LoudnessInfo {
        LoudnessInfo(integrated: integratedLUFS, truePeak: truePeakDBTP, range: loudnessRange)
    }

    // MARK: Internals

    static func lufs(energy: Double) -> Double { energy > 0 ? -0.691 + 10 * log10(energy) : -.infinity }
    static func energy(lufs: Double) -> Double { pow(10, (lufs + 0.691) / 10) }

    private static func mean(_ values: [Double], above threshold: Double) -> Double? {
        var sum = 0.0
        var count = 0
        for v in values where v > threshold { sum += v; count += 1 }
        return count > 0 ? sum / Double(count) : nil
    }

    /// K-weights each channel into a scratch buffer (`load` fills it with the channel's samples as Double),
    /// then accumulates weighted sums of squares per 100 ms sub-block.
    private mutating func ingest(frames: Int, load: (Int, UnsafeMutablePointer<Double>) -> Void) {
        // Split the chunk at sub-block boundaries.
        var segments: [Int] = []
        var remaining = frames
        var room = subBlockFrames - framesInSubBlock
        while remaining > 0 {
            let n = min(room, remaining)
            segments.append(n)
            remaining -= n
            room = subBlockFrames
        }
        var sums = [Double](repeating: 0, count: segments.count)
        var input = [Double](repeating: 0, count: frames)
        var filtered = [Double](repeating: 0, count: frames)
        let setup = biquad.setup
        input.withUnsafeMutableBufferPointer { inBuf in
            filtered.withUnsafeMutableBufferPointer { outBuf in
                let x = inBuf.baseAddress!, y = outBuf.baseAddress!
                for ch in 0..<channels {
                    let weight = channelWeights[ch]
                    if weight == 0 { continue }
                    load(ch, x)
                    delays[ch].withUnsafeMutableBufferPointer { d in
                        vDSP_biquadD(setup, d.baseAddress!, x, 1, y, 1, vDSP_Length(frames))
                    }
                    var offset = 0
                    for (i, n) in segments.enumerated() {
                        var s = 0.0
                        vDSP_svesqD(y + offset, 1, &s, vDSP_Length(n))
                        sums[i] += weight * s
                        offset += n
                    }
                }
            }
        }
        for (i, n) in segments.enumerated() {
            subBlockSum += sums[i]
            framesInSubBlock += n
            if framesInSubBlock == subBlockFrames { completeSubBlock() }
        }
    }

    private mutating func completeSubBlock() {
        recentSubBlocks.append(subBlockSum)
        if recentSubBlocks.count > 30 { recentSubBlocks.removeFirst(recentSubBlocks.count - 30) }
        subBlockSum = 0
        framesInSubBlock = 0
        let count = recentSubBlocks.count
        if count >= 4 {
            let sum = recentSubBlocks[(count - 4)...].reduce(0, +)
            blockEnergies.append(sum / Double(4 * subBlockFrames))
        }
        if count == 30 {
            let sum = recentSubBlocks.reduce(0, +)
            shortTermEnergies.append(sum / Double(30 * subBlockFrames))
        }
    }
}

/// Gain to bring a measured programme to a loudness target.
public enum LoudnessNormalizer {
    /// Gain in dB that moves `measured.integrated` to `target` LUFS. When no limiter will run
    /// (`limiterAvailable == false`) the gain is reduced so the predicted true peak
    /// (`measured.truePeak + gain`) stays at or under `ceiling` dBTP. Silent input gets 0 dB.
    public static func gain(measured: LoudnessInfo, target: Double, ceiling: Double, limiterAvailable: Bool) -> Double {
        guard measured.integrated.isFinite, measured.integrated > LoudnessMeter.absoluteGateLUFS,
              target.isFinite else { return 0 }
        var gain = target - measured.integrated
        if !limiterAvailable, measured.truePeak.isFinite, ceiling.isFinite {
            gain = min(gain, ceiling - measured.truePeak)
        }
        return gain
    }

    public static func linear(dB: Double) -> Double { pow(10, dB / 20) }
}
