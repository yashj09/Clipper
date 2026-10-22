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
/// - `sharpness`, `luma` and the clip's `ColorStats` come from the same sampled image at its sampled size (see
///   `FrameMeasure`), so they add no decode.
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
                        progress: (@Sendable (Double) -> Void)? = nil) async throws -> (activity: VisualActivity, color: ColorStats) {
        if info.kind == .image { return try await analyzeImage(url: url, progress: progress) }
        return try await offCooperativePool { try await analyzeVideo(url: url, info: info, range: range, progress: progress) }
    }

    private func analyzeVideo(url: URL, info: MediaInfo, range: ClosedRange<Double>?,
                              progress: (@Sendable (Double) -> Void)?) async throws -> (activity: VisualActivity, color: ColorStats) {
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { throw VisualAnalysisError.noVideoTrack(url) }
        var duration = info.duration.seconds
        if !(duration > 0) { duration = try await asset.load(.duration).seconds }
        let times = sampleTimes(duration: duration, range: range)

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

        return try assemble(results, url: url, progress: progress)
    }

    /// The requested sample times: every `interval` from the start of `range` (or 0), at least one.
    func sampleTimes(duration: Double, range: ClosedRange<Double>?) -> [Double] {
        let lo = max(0, range?.lowerBound ?? 0)
        let hi = min(range?.upperBound ?? duration, duration)
        let step = max(0.05, interval)
        var times: [Double] = []
        var t = lo
        while t < hi - 1e-3 { times.append(t); t = lo + Double(times.count) * step }
        if times.isEmpty { times = [min(lo, max(0, duration - 1e-3))] }
        return times
    }

    /// Stitches segments (the first sample of each is compared with the last of the one before), finds the cuts and
    /// takes the per-frame colour medians.
    func assemble(_ segments: [Segment], url: URL,
                  progress: (@Sendable (Double) -> Void)?) throws -> (activity: VisualActivity, color: ColorStats) {
        var samples: [VisualSample] = []
        var frames: [FrameMeasure] = []
        var previous: Signature?
        var firstError: String?
        for segment in segments {
            firstError = firstError ?? segment.error
            for (k, (var sample, frame)) in zip(segment.samples, segment.frames).enumerated() {
                if let last = samples.last, sample.time <= last.time + 1e-3 { continue }
                if k == 0 { sample.change = previous.map { Self.change($0, segment.first!) } ?? 0 }
                samples.append(sample)
                frames.append(frame)
            }
            if let last = segment.last { previous = last }
        }
        if samples.isEmpty { throw VisualAnalysisError.cannotRead(url, firstError ?? "no frames") }
        progress?(1)
        return (VisualActivity(samples: samples, sceneCuts: sceneCuts(samples)), FrameMeasure.median(frames))
    }

    struct Segment: Sendable {
        var samples: [VisualSample] = []
        /// Parallel to `samples`.
        var frames: [FrameMeasure] = []
        var first: Signature?
        var last: Signature?
        var error: String?
    }

    /// Fingerprints and (optionally) saliency-scans sampled images in time order: the per-image work shared by the
    /// image-generator path and the shared video ingest.
    struct SegmentBuilder {
        let saliency: Bool
        let request = GenerateAttentionBasedSaliencyImageRequest()
        private(set) var segment = Segment()

        init(saliency: Bool) { self.saliency = saliency }

        mutating func add(_ image: CGImage, at time: Double) async throws {
            if let last = segment.samples.last, time <= last.time + 1e-3 { return }   // same frame again
            guard let signature = Signature(image), let frame = FrameMeasure(image) else { return }
            var salient: NormRect?
            if saliency {
                let observation = try await request.perform(on: image)
                salient = VisualActivityAnalyzer.union(observation.salientObjects.map(\.boundingBox.cgRect))
            }
            let change = segment.last.map { VisualActivityAnalyzer.change($0, signature) } ?? 0
            segment.samples.append(VisualSample(time: time, change: change, salient: salient, sharpness: frame.sharpness,
                                                luma: frame.luma))
            segment.frames.append(frame)
            if segment.first == nil { segment.first = signature }
            segment.last = signature
        }

        mutating func fail(_ message: String) { segment.error = segment.error ?? message }
    }

    /// Generates, fingerprints and (optionally) saliency-scans the frames at `times`, in order.
    private func sample(asset: AVURLAsset, times: [Double], tick: @Sendable () -> Void) async throws -> Segment {
        let generator = Self.makeGenerator(asset: asset, maximumSize: maximumSize, tolerance: tolerance)
        defer { generator.cancelAllCGImageGeneration() }
        var builder = SegmentBuilder(saliency: saliency)
        for await result in generator.images(for: times.map { CMTime(seconds: $0, preferredTimescale: 600) }) {
            try Task.checkCancellation()
            defer { tick() }
            switch result {
            case .success(requestedTime: _, image: let image, actualTime: let actual):
                try await builder.add(image, at: actual.isNumeric ? actual.seconds : 0)
            case .failure(requestedTime: _, error: let error):
                builder.fail(error.localizedDescription)
            }
        }
        return builder.segment
    }

    private func analyzeImage(url: URL,
                              progress: (@Sendable (Double) -> Void)?) async throws -> (activity: VisualActivity, color: ColorStats) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,   // EXIF orientation → upright
                  kCGImageSourceThumbnailMaxPixelSize: Int(maximumSize),
              ] as CFDictionary) else {
            throw VisualAnalysisError.cannotRead(url, "unreadable image")
        }
        guard let frame = FrameMeasure(image) else { throw VisualAnalysisError.cannotRead(url, "unreadable image") }
        var salient: NormRect?
        if saliency {
            let observation = try await GenerateAttentionBasedSaliencyImageRequest().perform(on: image)
            salient = Self.union(observation.salientObjects.map(\.boundingBox.cgRect))
        }
        progress?(1)
        let sample = VisualSample(time: 0, change: 0, salient: salient, sharpness: frame.sharpness, luma: frame.luma)
        return (VisualActivity(samples: [sample], sceneCuts: []), FrameMeasure.median([frame]))
    }

    /// The generator configuration used for sampling (exposed for tests).
    static func makeGenerator(asset: AVAsset, maximumSize: Double, tolerance: Double) -> AVAssetImageGenerator {
        let g = AVAssetImageGenerator(asset: asset)
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: maximumSize, height: maximumSize)
        // HDR frames tone-mapped as the BT.709 renderer shows them, so HLG white is not read as mid-grey nor PQ
        // highlights as blown out.
        g.dynamicRangePolicy = .forceSDR
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

    // MARK: - Exposure, colour and sharpness

    /// What one sampled frame contributes to `VisualSample.sharpness`/`luma` and the clip's `ColorStats`, measured on
    /// its sRGB pixels at the sampled size.
    struct FrameMeasure: Sendable, Equatable {
        var luma: Double, p01: Double, p99: Double, saturation: Double
        var r: Double, g: Double, b: Double
        /// How much of the frame's Laplacian energy a 3×3 box blur removes, 0…1. A sharp edge loses nearly all of it
        /// and a soft one little, whatever the scene holds: a slide, a wall or the sky with one crisp edge reads
        /// sharp, and a defocused busy scene reads soft. A frame with no edges at all reads 0.
        var sharpness: Double

        /// Laplacian variance (8-bit units²) at which a frame counts as half flat. Below it the only "edges" left are
        /// the one-level steps 8-bit quantisation leaves in a smooth gradient, which the blur ratio would read as sharp.
        static let edgeFloor = 1.0

        init?(_ image: CGImage) {
            let w = image.width, h = image.height
            guard w > 0, h > 0 else { return nil }
            var rgba = [UInt8](repeating: 0, count: w * h * 4)
            let ok = rgba.withUnsafeMutableBytes { buf -> Bool in
                guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                      let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard ok else { return nil }
            self.init(rgba: rgba, width: w, height: h)
        }

        init(rgba: [UInt8], width w: Int, height h: Int) {
            let n = w * h
            var y = [Float](repeating: 0, count: n)
            var histogram = [Int](repeating: 0, count: 256)
            var sumR = 0, sumG = 0, sumB = 0, sumChroma = 0
            var sumY: Float = 0
            for i in 0..<n {
                let r = rgba[4 * i], g = rgba[4 * i + 1], b = rgba[4 * i + 2]
                let l = 0.2126 * Float(r) + 0.7152 * Float(g) + 0.0722 * Float(b)
                y[i] = l
                sumY += l
                histogram[min(255, Int(l.rounded()))] += 1
                sumR += Int(r); sumG += Int(g); sumB += Int(b)
                sumChroma += Int(max(r, g, b) - min(r, g, b))
            }
            var sharp = 0.0
            if w >= 5 && h >= 5 {
                var blurred = y
                for row in 1..<(h - 1) {
                    for col in 1..<(w - 1) {
                        let i = row * w + col
                        blurred[i] = (y[i - w - 1] + y[i - w] + y[i - w + 1] + y[i - 1] + y[i] + y[i + 1] + y[i + w - 1] + y[i + w] + y[i + w + 1]) / 9
                    }
                }
                func laplacianVariance(_ p: [Float]) -> Double {
                    var count = 0.0, sum = 0.0, sq = 0.0
                    for row in 2..<(h - 2) {
                        for col in 2..<(w - 2) {
                            let i = row * w + col
                            let lap = Double(4 * p[i] - p[i - 1] - p[i + 1] - p[i - w] - p[i + w])
                            count += 1; sum += lap; sq += lap * lap
                        }
                    }
                    return max(0, sq / count - (sum / count) * (sum / count))
                }
                let edges = laplacianVariance(y)
                if edges > 0 { sharp = max(0, 1 - laplacianVariance(blurred) / edges) * edges / (edges + Self.edgeFloor) }
            }
            func percentile(_ p: Double) -> Double {
                var seen = 0
                for (level, k) in histogram.enumerated() {
                    seen += k
                    if Double(seen) >= p * Double(n) { return Double(level) / 255 }
                }
                return 1
            }
            let total = Double(max(1, n)) * 255
            luma = Double(sumY) / total
            p01 = percentile(0.01); p99 = percentile(0.99)
            saturation = Double(sumChroma) / total
            r = Double(sumR) / total; g = Double(sumG) / total; b = Double(sumB) / total
            sharpness = sharp
        }

        /// Per-field medians; a scene that changes mid-clip does not drag the clip's statistics the way a mean would.
        static func median(_ frames: [FrameMeasure]) -> ColorStats {
            func m(_ field: KeyPath<FrameMeasure, Double>) -> Double {
                let v = frames.map { $0[keyPath: field] }.sorted()
                guard !v.isEmpty else { return 0 }
                return v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2
            }
            return ColorStats(luma: m(\.luma), p01: m(\.p01), p99: m(\.p99), saturation: m(\.saturation),
                              r: m(\.r), g: m(\.g), b: m(\.b))
        }
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
