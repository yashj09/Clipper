import AVFoundation

/// Band-limited sample-rate conversion of a whole mono signal in one continuous, stateful AVAudioConverter pass.
///
/// Why not let AVAssetReader resample? Asking `AVAssetReaderAudioMixOutput` for a different rate than the source
/// (e.g. 48 kHz AAC → 16 kHz) inserts discontinuities at buffer boundaries (measured: second-difference spikes 4–13×
/// a clean sine's). Decoding at the native rate and converting here is clean.
public enum Resampler {
    public static func resample(_ input: [Float], from source: Double, to target: Double) -> [Float] {
        guard source != target, !input.isEmpty,
              let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source, channels: 1, interleaved: false),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: target, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else { return input }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering

        let chunk = 65_536
        let expected = Int((Double(input.count) * target / source).rounded())
        var output: [Float] = []
        output.reserveCapacity(expected + chunk)
        nonisolated(unsafe) var position = 0  // the converter calls the input block synchronously on this thread
        let feed = Feed()
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(chunk)) else { return input }

        while true {
            outBuffer.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: outBuffer, error: &error) { requested, inputStatus in
                if feed.finished { inputStatus.pointee = .endOfStream; return nil }
                let n = min(Int(requested), input.count - position)
                guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(n)) else {
                    feed.finished = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                input.withUnsafeBufferPointer { src in
                    buf.floatChannelData![0].update(from: src.baseAddress! + position, count: n)
                }
                buf.frameLength = AVAudioFrameCount(n)
                position += n
                inputStatus.pointee = .haveData
                return buf
            }
            if outBuffer.frameLength > 0 {
                output.append(contentsOf: UnsafeBufferPointer(start: outBuffer.floatChannelData![0], count: Int(outBuffer.frameLength)))
            }
            if status == .endOfStream || status == .error || (status == .inputRanDry && feed.finished) { break }
        }
        // Converter latency can leave the length a few samples off; match the exact expected duration.
        if output.count > expected { output.removeLast(output.count - expected) }
        else if output.count < expected { output.append(contentsOf: repeatElement(0, count: expected - output.count)) }
        return output
    }

    private final class Feed { var finished = false }

    /// The highest native sample rate among `tracks` (what to decode at before resampling), or nil if unknown.
    public static func nativeSampleRate(of tracks: [AVAssetTrack]) async -> Double? {
        var best: Double?
        for t in tracks {
            guard let desc = try? await t.load(.formatDescriptions).first,
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee, asbd.mSampleRate > 0 else { continue }
            best = max(best ?? 0, asbd.mSampleRate)
        }
        return best
    }
}
