import AVFoundation

/// `Resampler` for audio that arrives in pieces (shared ingest): the same converter and settings, fed incrementally,
/// producing the same samples as `Resampler.resample` over the concatenated input — including its final length
/// (round(inputCount × target / source)). Not thread-safe; use from one queue.
public final class StreamingResampler {
    public let source: Double
    public let target: Double
    private let converter: AVAudioConverter?
    private let inFormat: AVAudioFormat?
    private let outBuffer: AVAudioPCMBuffer?
    private var pending: [Float] = []
    private var pendingOffset = 0
    private var inputCount = 0
    private var outputCount = 0
    private var ended = false
    private static let chunk = 65_536

    public init(from source: Double, to target: Double) {
        self.source = source
        self.target = target
        guard source != target,
              let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source, channels: 1, interleaved: false),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: target, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(Self.chunk))
        else { converter = nil; inFormat = nil; outBuffer = nil; return }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        self.converter = converter
        self.inFormat = inFormat
        self.outBuffer = outBuffer
    }

    /// Converts `input`, returning whatever output is ready (the converter holds back a little for its filter).
    public func push(_ input: UnsafeBufferPointer<Float>) -> [Float] {
        inputCount += input.count
        guard converter != nil else { outputCount += input.count; return Array(input) }
        pending.append(contentsOf: input)
        return drain()
    }

    /// Flushes the converter; with what `push` returned, the output has exactly the length `Resampler` produces.
    public func finish() -> [Float] {
        guard converter != nil else { return [] }
        ended = true
        var out = drain()
        let expected = Int((Double(inputCount) * target / source).rounded())
        let total = outputCount
        if total > expected { out.removeLast(min(out.count, total - expected)) }
        else if total < expected { out.append(contentsOf: repeatElement(0, count: expected - total)) }
        outputCount = expected
        return out
    }

    private func drain() -> [Float] {
        guard let converter, let inFormat, let outBuffer else { return [] }
        var output: [Float] = []
        while true {
            outBuffer.frameLength = 0
            var error: NSError?
            var gaveEnd = false
            let status = converter.convert(to: outBuffer, error: &error) { requested, inputStatus in
                let available = self.pending.count - self.pendingOffset
                if available == 0 {
                    if self.ended { gaveEnd = true; inputStatus.pointee = .endOfStream } else { inputStatus.pointee = .noDataNow }
                    return nil
                }
                let n = min(Int(requested), available)
                guard let buf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(n)) else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                self.pending.withUnsafeBufferPointer { src in
                    buf.floatChannelData![0].update(from: src.baseAddress! + self.pendingOffset, count: n)
                }
                buf.frameLength = AVAudioFrameCount(n)
                self.pendingOffset += n
                inputStatus.pointee = .haveData
                return buf
            }
            if outBuffer.frameLength > 0 {
                output.append(contentsOf: UnsafeBufferPointer(start: outBuffer.floatChannelData![0], count: Int(outBuffer.frameLength)))
            }
            if status == .error || status == .endOfStream || status == .inputRanDry || (gaveEnd && outBuffer.frameLength == 0) { break }
        }
        if pendingOffset > 0 {
            pending.removeFirst(pendingOffset)
            pendingOffset = 0
        }
        outputCount += output.count
        return output
    }
}
