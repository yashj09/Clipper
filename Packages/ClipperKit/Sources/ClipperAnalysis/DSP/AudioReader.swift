import AVFoundation
import ClipperCore
import ClipperEngine
import CoreMedia

public enum AudioReaderError: Error, Sendable, CustomStringConvertible {
    case noAudioTrack(URL)
    case cannotRead(URL, String)
    case invalidSampleRate(Double)

    public var description: String {
        switch self {
        case .noAudioTrack(let url): "No audio track in \(url.lastPathComponent)"
        case .cannotRead(let url, let why): "Cannot read audio from \(url.lastPathComponent): \(why)"
        case .invalidSampleRate(let sr): "Invalid sample rate \(sr)"
        }
    }
}

public enum AudioReader {
    /// Decodes all audio tracks of any AVFoundation-readable file, mixed down to mono Float32 at `sampleRate`.
    /// AVFoundation decodes and downmixes at the source's native rate; `Resampler` then converts the rate in one
    /// continuous pass (AVAssetReader's own resampling inserts clicks at buffer boundaries).
    /// - Parameter range: optional time range in seconds of the source; samples outside it are not decoded.
    public static func readMono(url: URL, sampleRate: Double, range: ClosedRange<Double>? = nil) async throws -> [Float] {
        guard sampleRate.isFinite, sampleRate > 0 else { throw AudioReaderError.invalidSampleRate(sampleRate) }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw AudioReaderError.noAudioTrack(url) }
        let native = await Resampler.nativeSampleRate(of: tracks) ?? sampleRate

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch {
            throw AudioReaderError.cannotRead(url, error.localizedDescription)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: native,
            AVNumberOfChannelsKey: 1,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioReaderError.cannotRead(url, "output not supported") }
        reader.add(output)

        var expected = 0
        if let range {
            let lo = max(0, range.lowerBound)
            let hi = max(lo, range.upperBound)
            let ts: CMTimeScale = 1_000_000
            reader.timeRange = CMTimeRange(start: CMTime(seconds: lo, preferredTimescale: ts),
                                           duration: CMTime(seconds: hi - lo, preferredTimescale: ts))
            expected = Int((hi - lo) * native) + 4096
        }
        guard reader.startReading() else {
            throw AudioReaderError.cannotRead(url, reader.error?.localizedDescription ?? "startReading failed")
        }

        var out: [Float] = []
        if expected > 0 { out.reserveCapacity(expected) }
        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); throw CancellationError() }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            let count = bytes / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            let old = out.count
            out.append(contentsOf: repeatElement(0, count: count))
            let status = out.withUnsafeMutableBufferPointer { dst in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                                           destination: UnsafeMutableRawPointer(dst.baseAddress! + old))
            }
            if status != kCMBlockBufferNoErr {
                reader.cancelReading()
                throw AudioReaderError.cannotRead(url, "CMBlockBufferCopyDataBytes failed (\(status))")
            }
        }
        if reader.status == .failed {
            throw AudioReaderError.cannotRead(url, reader.error?.localizedDescription ?? "reader failed")
        }
        return Resampler.resample(out, from: native, to: sampleRate)
    }
}
