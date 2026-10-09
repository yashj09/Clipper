import Accelerate
import Foundation

/// Look-ahead true-peak limiter.
///
/// For every frame it estimates the true peak (sample magnitude plus the BS.1770 Annex 2 interpolated
/// values on both sides of the sample, max over channels) and the gain that would bring it to the ceiling.
/// The gain curve is built so that it never exceeds that requirement:
///
/// 1. sliding minimum of the required gain over `lookahead + 2·margin` frames (hold),
/// 2. exponential release back towards unity (`min(hold, released)`, so it can only be lower),
/// 3. moving average over `lookahead` frames, which turns every gain drop into a linear ramp that
///    completes exactly when the peak reaches the output (attack = lookahead, no clicks).
///
/// The audio is delayed to line up with that gain (`latencyFrames`). The `margin` keeps the gain flat
/// for a few samples around each peak so the interpolated (inter-sample) peak is also held down.
/// When the input never exceeds the ceiling, the gain is exactly 1 and the output is the delayed input.
public struct TruePeakLimiter: Sendable {
    public let sampleRate: Double
    public let channels: Int
    public let ceilingDBTP: Double
    public let lookaheadFrames: Int
    public let releaseSeconds: Double

    /// Half-width (frames) of the flat region kept around each peak; covers the interpolator's taps.
    private static let margin = TruePeakFIR.delay

    private let ceiling: Float
    private let releaseCoefficient: Double

    // Interpolator state.
    private var firHistory: [[Float]]
    private var magnitudeHistory: [Float]   // per-frame max |x| for the last `TruePeakFIR.delay` frames
    private var lastInterpolated: Float = 0

    // Gain computer state.
    private var hold: SlidingMinimum
    private var releaseGain = 1.0
    private var box: [Double]
    private var boxIndex = 0
    private var boxSum: Double

    // Audio delay line (interleaved, `latencyFrames` frames).
    private var delayLine: [Float]

    /// Lowest gain applied so far (linear), for diagnostics.
    public private(set) var minimumGain: Float = 1

    public init(sampleRate: Double, channels: Int, ceilingDBTP: Double = -1.0) {
        self.init(sampleRate: sampleRate, channels: channels, ceilingDBTP: ceilingDBTP,
                  lookaheadSeconds: 0.005, releaseSeconds: 0.08)
    }

    public init(sampleRate: Double, channels: Int, ceilingDBTP: Double, lookaheadSeconds: Double, releaseSeconds: Double) {
        precondition(sampleRate > 0 && channels > 0, "invalid limiter format")
        self.sampleRate = sampleRate
        self.channels = channels
        self.ceilingDBTP = ceilingDBTP
        self.releaseSeconds = releaseSeconds
        lookaheadFrames = max(1, Int((lookaheadSeconds * sampleRate).rounded()))
        ceiling = Float(pow(10, ceilingDBTP / 20))
        releaseCoefficient = releaseSeconds > 0 ? exp(-1 / (releaseSeconds * sampleRate)) : 0
        firHistory = Array(repeating: Array(repeating: 0, count: TruePeakFIR.history), count: channels)
        magnitudeHistory = Array(repeating: 0, count: TruePeakFIR.delay)
        hold = SlidingMinimum(window: lookaheadFrames + 2 * Self.margin)
        box = Array(repeating: 1, count: lookaheadFrames)
        boxSum = Double(lookaheadFrames)
        let latency = TruePeakFIR.delay + lookaheadFrames - 1 + Self.margin
        delayLine = Array(repeating: 0, count: latency * channels)
    }

    /// Output frame `n` is input frame `n - latencyFrames`.
    public var latencyFrames: Int { TruePeakFIR.delay + lookaheadFrames - 1 + Self.margin }

    /// Limits `interleaved` in place (streaming; the output is delayed by `latencyFrames`).
    /// The sample count must be a multiple of `channels`.
    public mutating func process(_ interleaved: inout [Float]) {
        let frames = interleaved.count / channels
        precondition(frames * channels == interleaved.count, "sample count must be a multiple of channels")
        guard frames > 0 else { return }

        // 1. Per-frame peak magnitudes: max |x| and max interpolated |x| over channels.
        let h = TruePeakFIR.history
        let work = UnsafeMutablePointer<Float>.allocate(capacity: 5 * frames + h)
        defer { work.deallocate() }
        work.initialize(repeating: 0, count: 5 * frames + h)
        let magnitude = work                       // frames
        let interpolated = work + frames           // frames
        let scratch = work + 2 * frames            // frames
        let branch = work + 3 * frames             // frames
        let buffer = work + 4 * frames             // h + frames
        let channels = self.channels
        let n = vDSP_Length(frames)
        interleaved.withUnsafeBufferPointer { src in
            for ch in 0..<channels {
                firHistory[ch].withUnsafeBufferPointer { buffer.update(from: $0.baseAddress!, count: h) }
                var one: Float = 1
                vDSP_vsmul(src.baseAddress! + ch, vDSP_Stride(channels), &one, buffer + h, 1, n)
                vDSP_vmaxmg(buffer + h, 1, magnitude, 1, magnitude, 1, n)
                TruePeakFIR.interpolatedMagnitudes(buffer, count: frames, scratch: scratch, out: branch)
                vDSP_vmax(branch, 1, interpolated, 1, interpolated, 1, n)
                firHistory[ch] = Array(UnsafeBufferPointer(start: buffer + frames, count: h))
            }
        }

        // 2. Gain per frame, applied to the delayed audio.
        let latency = latencyFrames
        var combined = delayLine
        combined.append(contentsOf: interleaved)
        let d = TruePeakFIR.delay
        let ceiling = self.ceiling
        let lookahead = Double(lookaheadFrames)
        for j in 0..<frames {
            // Frame j (absolute n) completes the interpolation of the interval (n-6, n-5): evaluate the peak
            // at sample m = n-6 from its own magnitude and both neighbouring intervals.
            let sampleMagnitude = j >= d ? magnitude[j - d] : magnitudeHistory[j]
            let previous = j > 0 ? interpolated[j - 1] : lastInterpolated
            let peak = max(sampleMagnitude, interpolated[j], previous)
            let required = peak > ceiling ? Double(ceiling / peak) : 1

            let held = hold.push(required)
            releaseGain = min(held, 1 - (1 - releaseGain) * releaseCoefficient)

            boxSum += releaseGain - box[boxIndex]
            box[boxIndex] = releaseGain
            boxIndex += 1
            if boxIndex == box.count {
                boxIndex = 0
                boxSum = box.reduce(0, +)  // re-sync to stop rounding drift
            }
            let gain = Float(min(1, boxSum / lookahead))
            minimumGain = min(minimumGain, gain)

            let base = j * channels
            if gain == 1 {
                for c in 0..<channels { interleaved[base + c] = combined[base + c] }
            } else {
                for c in 0..<channels { interleaved[base + c] = combined[base + c] * gain }
            }
        }

        // 3. Carry state into the next call.
        if frames >= d {
            magnitudeHistory = Array(UnsafeBufferPointer(start: magnitude + frames - d, count: d))
        } else {
            magnitudeHistory = Array((magnitudeHistory + UnsafeBufferPointer(start: magnitude, count: frames)).suffix(d))
        }
        lastInterpolated = interpolated[frames - 1]
        delayLine = Array(combined.suffix(latency * channels))
    }

    /// Pushes `latencyFrames` of silence through and returns the delayed tail of the stream.
    public mutating func flush() -> [Float] {
        var tail = [Float](repeating: 0, count: latencyFrames * channels)
        process(&tail)
        return tail
    }
}

/// Minimum over the last `window` pushed values (monotonic deque in a ring buffer).
struct SlidingMinimum: Sendable {
    let window: Int
    private var indices: [Int]
    private var values: [Double]
    private var head = 0
    private var count = 0
    private var position = 0

    init(window: Int) {
        self.window = max(1, window)
        indices = Array(repeating: 0, count: self.window + 1)
        values = Array(repeating: 0, count: self.window + 1)
    }

    /// Adds `value` and returns the minimum of the last `window` values (fewer at the start).
    mutating func push(_ value: Double) -> Double {
        let capacity = indices.count
        // Drop larger-or-equal values from the back: they can never be the minimum again.
        while count > 0 {
            let back = (head + count - 1) % capacity
            if values[back] >= value { count -= 1 } else { break }
        }
        let slot = (head + count) % capacity
        indices[slot] = position
        values[slot] = value
        count += 1
        // Drop expired values from the front.
        while indices[head] <= position - window {
            head = (head + 1) % capacity
            count -= 1
        }
        position += 1
        return values[head]
    }
}
