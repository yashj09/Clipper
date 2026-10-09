import AVFoundation
import ClipperCore
import CoreGraphics

/// Filmstrip thumbnails for the timeline, generated off the main thread and cached in memory.
/// Times are quantized to a per-asset grid so scrolling and zooming reuse the same images.
public actor Thumbnailer {
    public static let shared = Thumbnailer()

    private var generators: [URL: AVAssetImageGenerator] = [:]
    private var cache: [String: CGImage] = [:]
    private var order: [String] = []
    private let limit = 4000

    public init() {}

    /// Thumbnail near `time` (seconds) of `url`, `height` pixels tall, upright (rotation applied).
    public func thumbnail(_ url: URL, at time: Double, height: Int = 96, grid: Double = 0.5) async -> CGImage? {
        let q = (time / grid).rounded() * grid
        let key = "\(url.path)|\(q)|\(height)"
        if let hit = cache[key] { return hit }
        let gen = generator(url, height: height)
        let image = try? await gen.image(at: CMTime(seconds: q, preferredTimescale: 600)).image
        if let image {
            cache[key] = image
            order.append(key)
            if order.count > limit { cache[order.removeFirst()] = nil }
        }
        return image
    }

    private func generator(_ url: URL, height: Int) -> AVAssetImageGenerator {
        if let g = generators[url] { return g }
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: height * 4, height: height)
        // Thumbnails don't need exact frames; a tolerance lets the decoder use nearby keyframes (much faster).
        g.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        g.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
        generators[url] = g
        return g
    }
}

/// Min/max peak pyramid for drawing waveforms at any zoom level.
public struct WaveformPeaks: Sendable, Codable {
    /// Samples per bucket at level 0 (finest); each further level halves the resolution.
    public static let baseBucket = 256
    public var sampleRate: Double
    /// levels[l][i] = (min, max) of bucket i at level l, interleaved [min0, max0, min1, max1, …].
    public var levels: [[Float]]

    public var duration: Double { Double((levels.first?.count ?? 0) / 2 * Self.baseBucket) / sampleRate }

    /// Peaks for `seconds` per output column: picks the coarsest level that still has ≥ 1 bucket per column.
    public func peaks(from start: Double, to end: Double, columns: Int) -> [(Float, Float)] {
        guard columns > 0, end > start, let base = levels.first, !base.isEmpty else { return [] }
        let secondsPerColumn = (end - start) / Double(columns)
        var level = 0
        while level + 1 < levels.count,
              secondsPerColumn >= Double(Self.baseBucket << (level + 1)) / sampleRate { level += 1 }
        let data = levels[level]
        let bucketSeconds = Double(Self.baseBucket << level) / sampleRate
        var out: [(Float, Float)] = []
        out.reserveCapacity(columns)
        for c in 0..<columns {
            let a = Int(((start + Double(c) * secondsPerColumn) / bucketSeconds).rounded(.down))
            let b = max(a + 1, Int(((start + Double(c + 1) * secondsPerColumn) / bucketSeconds).rounded(.up)))
            var lo: Float = 0, hi: Float = 0
            var i = max(a, 0)
            while i < min(b, data.count / 2) { lo = min(lo, data[2 * i]); hi = max(hi, data[2 * i + 1]); i += 1 }
            out.append((lo, hi))
        }
        return out
    }

    /// Decodes the audio of `url` (mono mix at 22.05 kHz) and builds the pyramid.
    public static func build(url: URL) async throws -> WaveformPeaks {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return WaveformPeaks(sampleRate: 22_050, levels: []) }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 22_050, AVNumberOfChannelsKey: 1])
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        var level0: [Float] = []
        var lo: Float = 0, hi: Float = 0, n = 0
        while let sb = out.copyNextSampleBuffer() {
            try Task.checkCancellation()
            for s in AudioSampleBuffers.floats(sb) {
                lo = min(lo, s); hi = max(hi, s); n += 1
                if n == baseBucket { level0.append(lo); level0.append(hi); lo = 0; hi = 0; n = 0 }
            }
        }
        if n > 0 { level0.append(lo); level0.append(hi) }
        var levels = [level0]
        while let last = levels.last, last.count > 4 {
            var next: [Float] = []
            next.reserveCapacity(last.count / 2 + 2)
            var i = 0
            while i < last.count {
                let j = i + 2
                next.append(min(last[i], j < last.count ? last[j] : 0))
                next.append(max(last[i + 1], j + 1 < last.count ? last[j + 1] : 0))
                i += 4
            }
            levels.append(next)
        }
        return WaveformPeaks(sampleRate: 22_050, levels: levels)
    }
}
