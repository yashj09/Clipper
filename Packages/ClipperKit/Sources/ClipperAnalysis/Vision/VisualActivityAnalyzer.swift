import AVFoundation
import ClipperCore
import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Vision

public enum VisualAnalysisError: Error, Sendable, CustomStringConvertible {
    case noVideoTrack(URL)
    case cannotRead(URL, String)

    public var description: String {
        switch self {
        case .noVideoTrack(let url): "No video track in \(url.lastPathComponent)"
        case .cannotRead(let url, let why): "Cannot read frames from \(url.lastPathComponent): \(why)"
        }
    }
}

/// Coarse visual activity of long recordings: frame-to-frame change, scene cuts, and the most salient region,
/// sampled every `interval` seconds — without decoding every frame.
///
/// - Sampling: `AVAssetImageGenerator` with ±`tolerance` (default 0.5 s), `maximumSize` (256 px) and
///   `appliesPreferredTrackTransform`, so images are small and already display-oriented. With a keyframe within the
///   tolerance the generator returns it; otherwise it decodes forward from the previous keyframe (cheap at this size:
///   measured ~3–14 ms per sample for 1080p60 HEVC with a 2 s GOP). The sample time is the frame actually returned.
///   The requested times are split into `concurrency` contiguous segments, each with its own generator (decode is
///   the bottleneck; 4 parallel generators are ~1.4× faster than one on an M4 Pro).
/// - `change`: difference to the previous sample on a 64×36 RGB thumbnail, 0…1:
///   ½ · (total-variation distance of 4×4×4 colour histograms) + ½ · min(1, 2 · mean absolute RGB difference).
///   The histogram term reacts to new content, the pixel term to layout changes of similar colours.
/// - `sceneCuts`: samples whose change exceeds max(`minCutChange`, mean + `cutSigma`·σ of the changes within
///   ±`cutWindow` samples, excluding itself) and is a local maximum. A cut is reported halfway between the two samples
///   (±interval/2 accuracy).
/// - `salient`: Vision attention-based saliency; the union of its salient objects (top-left origin, normalized to
///   the display-oriented frame), nil when Vision finds none.
/// - Still images (`kind == .image`) yield one sample at t = 0 (EXIF orientation applied).
public struct VisualActivityAnalyzer: Sendable {
    public var interval: Double = 1.0
    public var saliency = true
    /// Allowed distance (seconds) between requested and returned frame.
    public var tolerance: Double = 0.5
    /// Longest side of the sampled images, in pixels.
    public var maximumSize: Double = 256
    /// Parallel image generators (segments of the timeline).
    public var concurrency: Int = 4
    public var minCutChange: Double = 0.3
    public var cutSigma: Double = 3
    /// Samples on each side used for the adaptive cut threshold.
    public var cutWindow: Int = 30

    public init(interval: Double = 1.0, saliency: Bool = true) {
        self.interval = interval
        self.saliency = saliency
    }

    /// - Parameter progress: fraction 0…1 of the samples produced so far.
    public func analyze(url: URL, info: MediaInfo, range: ClosedRange<Double>? = nil,
                        progress: (@Sendable (Double) -> Void)? = nil) async throws -> VisualActivity {
        if info.kind == .image { return try await analyzeImage(url: url, progress: progress) }
        return try await offCooperativePool { try await analyzeVideo(url: url, info: info, range: range, progress: progress) }
    }

    private func analyzeVideo(url: URL, info: MediaInfo, range: ClosedRange<Double>?,
                              progress: (@Sendable (Double) -> Void)?) async throws -> VisualActivity {
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { throw VisualAnalysisError.noVideoTrack(url) }
        var duration = info.duration.seconds
        if !(duration > 0) { duration = try await asset.load(.duration).seconds }
        let lo = max(0, range?.lowerBound ?? 0)
        let hi = min(range?.upperBound ?? duration, duration)
        let step = max(0.05, interval)
        var times: [Double] = []
        var t = lo
        while t < hi - 1e-3 { times.append(t); t = lo + Double(times.count) * step }
        if times.isEmpty { times = [min(lo, max(0, duration - 1e-3))] }

        let parts = max(1, min(concurrency, times.count / 16))
        let per = (times.count + parts - 1) / parts
        let segments = stride(from: 0, to: times.count, by: per).map { Array(times[$0..<min(times.count, $0 + per)]) }
        let done = Mutex(0)
        let total = Double(times.count)
        let tick: @Sendable () -> Void = {
            let n = done.withLock { $0 += 1; return $0 }
            progress?(min(1, Double(n) / total))
        }
        let config = self
        let results = try await withThrowingTaskGroup(of: (Int, Segment).self, returning: [Segment].self) { group in
            for (i, segment) in segments.enumerated() {
                group.addTask { (i, try await config.sample(asset: asset, times: segment, tick: tick)) }
            }
            var out = [Segment?](repeating: nil, count: segments.count)
            for try await (i, s) in group { out[i] = s }
            return out.compactMap { $0 }
        }

        // Stitch segments: the first sample of each segment is compared with the last of the one before.
        var samples: [VisualSample] = []
        var previous: Signature?
        var firstError: String?
        for segment in results {
            firstError = firstError ?? segment.error
            for (k, var sample) in segment.samples.enumerated() {
                if let last = samples.last, sample.time <= last.time + 1e-3 { continue }
                if k == 0 { sample.change = previous.map { Self.change($0, segment.first!) } ?? 0 }
                samples.append(sample)
            }
            if let last = segment.last { previous = last }
        }
        if samples.isEmpty, let firstError { throw VisualAnalysisError.cannotRead(url, firstError) }
        progress?(1)
        return VisualActivity(samples: samples, sceneCuts: sceneCuts(samples))
    }

    private struct Segment: Sendable {
        var samples: [VisualSample] = []
        var first: Signature?
        var last: Signature?
        var error: String?
    }

    /// Generates, fingerprints and (optionally) saliency-scans the frames at `times`, in order.
    private func sample(asset: AVURLAsset, times: [Double], tick: @Sendable () -> Void) async throws -> Segment {
        let generator = Self.makeGenerator(asset: asset, maximumSize: maximumSize, tolerance: tolerance)
        defer { generator.cancelAllCGImageGeneration() }
        let request = GenerateAttentionBasedSaliencyImageRequest()
        var segment = Segment()
        for await result in generator.images(for: times.map { CMTime(seconds: $0, preferredTimescale: 600) }) {
            try Task.checkCancellation()
            defer { tick() }
            switch result {
            case .success(requestedTime: _, image: let image, actualTime: let actual):
                let time = actual.isNumeric ? actual.seconds : 0
                if let last = segment.samples.last, time <= last.time + 1e-3 { continue }   // same frame again
                guard let signature = Signature(image) else { continue }
                var salient: NormRect?
                if saliency {
                    let observation = try await request.perform(on: image)
                    salient = Self.union(observation.salientObjects.map(\.boundingBox.cgRect))
                }
                let change = segment.last.map { Self.change($0, signature) } ?? 0
                segment.samples.append(VisualSample(time: time, change: change, salient: salient))
                if segment.first == nil { segment.first = signature }
                segment.last = signature
            case .failure(requestedTime: _, error: let error):
                segment.error = segment.error ?? error.localizedDescription
            }
        }
        return segment
    }

    private func analyzeImage(url: URL, progress: (@Sendable (Double) -> Void)?) async throws -> VisualActivity {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,   // EXIF orientation → upright
                  kCGImageSourceThumbnailMaxPixelSize: Int(maximumSize),
              ] as CFDictionary) else {
            throw VisualAnalysisError.cannotRead(url, "unreadable image")
        }
        var salient: NormRect?
        if saliency {
            let observation = try await GenerateAttentionBasedSaliencyImageRequest().perform(on: image)
            salient = Self.union(observation.salientObjects.map(\.boundingBox.cgRect))
        }
        progress?(1)
        return VisualActivity(samples: [VisualSample(time: 0, change: 0, salient: salient)], sceneCuts: [])
    }

    /// The generator configuration used for sampling (exposed for tests).
    static func makeGenerator(asset: AVAsset, maximumSize: Double, tolerance: Double) -> AVAssetImageGenerator {
        let g = AVAssetImageGenerator(asset: asset)
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: maximumSize, height: maximumSize)
        let tol = CMTime(seconds: max(0, tolerance), preferredTimescale: 600)
        g.requestedTimeToleranceBefore = tol
        g.requestedTimeToleranceAfter = tol
        return g
    }

    /// Union of Vision rects (lower-left origin) as a top-left-origin `NormRect`; nil for none or an empty union.
    static func union(_ rects: [CGRect]) -> NormRect? {
        guard var u = rects.first else { return nil }
        for r in rects.dropFirst() { u = u.union(r) }
        let rect = FaceAnalyzer.topLeftRect(u)
        return rect.width > 0 && rect.height > 0 ? rect : nil
    }

    // MARK: - Change and cuts

    /// 64×36 RGB thumbnail plus a 64-bin (4×4×4) colour histogram.
    struct Signature: Sendable {
        static let width = 64, height = 36
        var rgb: [UInt8]
        var histogram: [Float]

        init?(_ image: CGImage) {
            let w = Self.width, h = Self.height
            var rgba = [UInt8](repeating: 0, count: w * h * 4)
            let ok = rgba.withUnsafeMutableBytes { buf -> Bool in
                guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                      let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
                ctx.interpolationQuality = .medium
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard ok else { return nil }
            self.init(rgba: rgba)
        }

        init(rgba: [UInt8]) {
            var rgb = [UInt8](repeating: 0, count: rgba.count / 4 * 3)
            var histogram = [Float](repeating: 0, count: 64)
            let n = rgba.count / 4
            for i in 0..<n {
                let r = rgba[4 * i], g = rgba[4 * i + 1], b = rgba[4 * i + 2]
                rgb[3 * i] = r; rgb[3 * i + 1] = g; rgb[3 * i + 2] = b
                histogram[Int(r >> 6) << 4 | Int(g >> 6) << 2 | Int(b >> 6)] += 1
            }
            if n > 0 { for k in 0..<64 { histogram[k] /= Float(n) } }
            self.rgb = rgb
            self.histogram = histogram
        }
    }

    /// 0 (identical) … 1 (black ↔ white): ½·histogram TV distance + ½·min(1, 2·mean |ΔRGB|).
    static func change(_ a: Signature, _ b: Signature) -> Double {
        guard a.rgb.count == b.rgb.count, !a.rgb.isEmpty else { return 1 }
        var sum = 0
        for i in 0..<a.rgb.count { sum += abs(Int(a.rgb[i]) - Int(b.rgb[i])) }
        let pixel = Double(sum) / Double(a.rgb.count) / 255
        var tv: Float = 0
        for k in 0..<64 { tv += abs(a.histogram[k] - b.histogram[k]) }
        return min(1, max(0, 0.5 * Double(tv / 2) + 0.5 * min(1, 2 * pixel)))
    }

    /// Adaptive-threshold peak picking over `samples[k].change` (see the type's documentation).
    func sceneCuts(_ samples: [VisualSample]) -> [Double] {
        guard samples.count >= 2 else { return [] }
        let c = samples.map(\.change)
        var cuts: [Double] = []
        for k in 1..<c.count {
            let a = max(1, k - cutWindow), b = min(c.count - 1, k + cutWindow)
            var n = 0.0, sum = 0.0, sq = 0.0
            for j in a...b where j != k { n += 1; sum += c[j]; sq += c[j] * c[j] }
            let mean = n > 0 ? sum / n : 0
            let sd = n > 0 ? max(0, sq / n - mean * mean).squareRoot() : 0
            let threshold = max(minCutChange, mean + cutSigma * sd)
            let isPeak = (k == 1 || c[k] >= c[k - 1]) && (k == c.count - 1 || c[k] > c[k + 1])
            if c[k] > threshold && isPeak { cuts.append((samples[k - 1].time + samples[k].time) / 2) }
        }
        return cuts
    }
}
