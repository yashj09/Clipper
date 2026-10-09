import Accelerate
import Foundation

/// The ITU-R BS.1770-4 Annex 2 true-peak interpolator: a 48-tap FIR split into four 12-tap polyphase
/// branches (4x oversampling). Branch `p` estimates the signal a quarter-sample-ish between input samples;
/// together with the original samples this gives the true-peak estimate.
///
/// Branch outputs at input index `n` lie between samples `n-6` and `n-5` (the filter's group delay is 5.5).
enum TruePeakFIR {
    static let tapsPerPhase = 12
    /// Samples of history each channel must carry between calls.
    static let history = tapsPerPhase - 1
    /// Interpolated values computed at input index `n` describe the interval (n - delay, n - delay + 1).
    static let delay = 6

    static let phases: [[Float]] = [
        [0.0017089843750, 0.0109863281250, -0.0196533203125, 0.0332031250000, -0.0594482421875, 0.1373291015625,
         0.9721679687500, -0.1022949218750, 0.0476074218750, -0.0266113281250, 0.0148925781250, -0.0083007812500],
        [-0.0291748046875, 0.0292968750000, -0.0517578125000, 0.0891113281250, -0.1665039062500, 0.4650878906250,
         0.7797851562500, -0.2003173828125, 0.1015625000000, -0.0582275390625, 0.0330810546875, -0.0189208984375],
        [-0.0189208984375, 0.0330810546875, -0.0582275390625, 0.1015625000000, -0.2003173828125, 0.7797851562500,
         0.4650878906250, -0.1665039062500, 0.0891113281250, -0.0517578125000, 0.0292968750000, -0.0291748046875],
        [-0.0083007812500, 0.0148925781250, -0.0266113281250, 0.0476074218750, -0.1022949218750, 0.9721679687500,
         0.1373291015625, -0.0594482421875, 0.0332031250000, -0.0196533203125, 0.0109863281250, 0.0017089843750],
    ]

    /// vDSP_conv computes a correlation, so the taps are stored reversed to get a convolution.
    static let reversedPhases: [[Float]] = phases.map { Array($0.reversed()) }

    /// `buffer` holds `history` samples of past input followed by `count` new samples (contiguous).
    /// Writes `max(|branch_p(n)|)` over the four branches for every new sample `n` into `out` (count values),
    /// using `scratch` (count values) as working memory.
    static func interpolatedMagnitudes(_ buffer: UnsafePointer<Float>, count: Int,
                                       scratch: UnsafeMutablePointer<Float>, out: UnsafeMutablePointer<Float>) {
        let n = vDSP_Length(count)
        vDSP_vclr(out, 1, n)
        for taps in reversedPhases {
            taps.withUnsafeBufferPointer { t in
                vDSP_conv(buffer, 1, t.baseAddress!, 1, scratch, 1, n, vDSP_Length(tapsPerPhase))
            }
            vDSP_vmaxmg(scratch, 1, out, 1, out, 1, n)
        }
    }

    /// Largest interpolated magnitude for the new samples in `buffer` (same layout as above).
    static func maxInterpolated(_ buffer: UnsafePointer<Float>, count: Int, scratch: UnsafeMutablePointer<Float>) -> Float {
        var peak: Float = 0
        let n = vDSP_Length(count)
        for taps in reversedPhases {
            taps.withUnsafeBufferPointer { t in
                vDSP_conv(buffer, 1, t.baseAddress!, 1, scratch, 1, n, vDSP_Length(tapsPerPhase))
            }
            var m: Float = 0
            vDSP_maxmgv(scratch, 1, &m, n)
            peak = max(peak, m)
        }
        return peak
    }
}

/// Streaming BS.1770-4 true-peak meter (4x oversampling, Annex 2 interpolator).
/// The result is the larger of the sample peak and the interpolated peak, per channel, as dBTP.
/// The 4x interpolator is used at every sample rate (at ≥ 96 kHz it simply over-estimates less often).
public struct TruePeakDetector: Sendable {
    public let channels: Int
    /// Per-channel linear true peak so far.
    public private(set) var channelPeaks: [Float]
    /// Per-channel linear sample peak so far.
    public private(set) var samplePeaks: [Float]
    private var history: [[Float]]

    public init(channels: Int) {
        precondition(channels > 0, "TruePeakDetector needs at least one channel")
        self.channels = channels
        channelPeaks = Array(repeating: 0, count: channels)
        samplePeaks = Array(repeating: 0, count: channels)
        history = Array(repeating: Array(repeating: 0, count: TruePeakFIR.history), count: channels)
    }

    /// Interleaved samples; the frame count is `count / channels`.
    public mutating func process(interleaved: UnsafeBufferPointer<Float>) {
        guard let base = interleaved.baseAddress else { return }
        let frames = interleaved.count / channels
        guard frames > 0 else { return }
        let stride = channels
        ingest(frames: frames) { ch, dst in
            var one: Float = 1
            vDSP_vsmul(base + ch, vDSP_Stride(stride), &one, dst, 1, vDSP_Length(frames))
        }
    }

    /// One array per channel (all the same length).
    public mutating func process(planar: [[Float]]) {
        precondition(planar.count == channels, "planar channel count mismatch")
        let frames = planar.map(\.count).min() ?? 0
        guard frames > 0 else { return }
        ingest(frames: frames) { ch, dst in
            planar[ch].withUnsafeBufferPointer { src in
                dst.update(from: src.baseAddress!, count: frames)
            }
        }
    }

    public var peakLinear: Double { Double(channelPeaks.max() ?? 0) }

    /// Max over channels in dBTP; -120 for digital silence.
    public var peakDBTP: Double { Self.decibels(peakLinear) }

    public var samplePeakDBFS: Double { Self.decibels(Double(samplePeaks.max() ?? 0)) }

    static func decibels(_ linear: Double) -> Double {
        linear > 0 ? max(20 * log10(linear), LoudnessMeter.silenceFloor) : LoudnessMeter.silenceFloor
    }

    private mutating func ingest(frames: Int, load: (Int, UnsafeMutablePointer<Float>) -> Void) {
        let h = TruePeakFIR.history
        var buffer = [Float](repeating: 0, count: h + frames)
        var scratch = [Float](repeating: 0, count: frames)
        buffer.withUnsafeMutableBufferPointer { buf in
            scratch.withUnsafeMutableBufferPointer { scr in
                let b = buf.baseAddress!
                for ch in 0..<channels {
                    history[ch].withUnsafeBufferPointer { b.update(from: $0.baseAddress!, count: h) }
                    load(ch, b + h)
                    var sample: Float = 0
                    vDSP_maxmgv(b + h, 1, &sample, vDSP_Length(frames))
                    let interpolated = TruePeakFIR.maxInterpolated(b, count: frames, scratch: scr.baseAddress!)
                    samplePeaks[ch] = max(samplePeaks[ch], sample)
                    channelPeaks[ch] = max(channelPeaks[ch], sample, interpolated)
                    history[ch] = Array(buf[frames..<(frames + h)])
                }
            }
        }
    }
}
