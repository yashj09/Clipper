import AVFoundation
import ClipperCore
import CoreMedia
import Foundation
import ImageIO
import Vision

public enum FaceAnalysisError: Error, Sendable, CustomStringConvertible {
    case noVideoTrack(URL)
    case cannotRead(URL, String)

    public var description: String {
        switch self {
        case .noVideoTrack(let url): "No video track in \(url.lastPathComponent)"
        case .cannotRead(let url, let why): "Cannot read video from \(url.lastPathComponent): \(why)"
        }
    }
}

/// Samples a video at `samplesPerSecond` and records the largest detected face per sample (used by Reframe).
///
/// Frames are decoded sequentially with `AVAssetReader` (8-bit 4:2:0, the decoder's cheapest output, HDR included);
/// frames between samples are decoded but skipped. Vision is told the frame's display orientation, derived from
/// `MediaInfo.rotation`/`mirrored`, so rects come back in display space; they are stored with a top-left origin.
/// Samples with no face are omitted. Still images (`kind == .image`) produce one sample at t = 0.
public struct FaceAnalyzer: Sendable {
    public var samplesPerSecond: Double = 4
    /// Faces whose Vision confidence is below this are ignored.
    public var minConfidence: Double = 0.5

    public init(samplesPerSecond: Double = 4) { self.samplesPerSecond = samplesPerSecond }

    public func analyze(url: URL, info: MediaInfo, range: ClosedRange<Double>? = nil) async throws -> FaceTrack {
        try await analyze(url: url, info: info, range: range, progress: nil)
    }

    /// - Parameter progress: fraction 0…1 of the (range of the) video processed so far.
    public func analyze(url: URL, info: MediaInfo, range: ClosedRange<Double>?,
                        progress: (@Sendable (Double) -> Void)?) async throws -> FaceTrack {
        if info.kind == .image { return try await analyzeImage(url: url) }
        return try await offCooperativePool { try await decodeAndDetect(url: url, info: info, range: range, progress: progress) }
    }

    private func decodeAndDetect(url: URL, info: MediaInfo, range: ClosedRange<Double>?,
                                 progress: (@Sendable (Double) -> Void)?) async throws -> FaceTrack {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw FaceAnalysisError.noVideoTrack(url) }
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw FaceAnalysisError.cannotRead(url, error.localizedDescription) }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw FaceAnalysisError.cannotRead(url, "output not supported") }
        reader.add(output)

        let duration = info.duration.seconds
        let lo = max(0, range?.lowerBound ?? 0)
        let hi = range.map { min($0.upperBound, duration > 0 ? duration : $0.upperBound) } ?? duration
        if let range {
            reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, range.lowerBound), preferredTimescale: 600),
                                           duration: CMTime(seconds: max(0, range.upperBound - max(0, range.lowerBound)),
                                                            preferredTimescale: 600))
        }
        guard reader.startReading() else {
            throw FaceAnalysisError.cannotRead(url, reader.error?.localizedDescription ?? "startReading failed")
        }
        defer { if reader.status == .reading { reader.cancelReading() } }

        var sampler = Sampler(self, info: info)
        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); throw CancellationError() }
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            guard pts.isNumeric, let pixels = CMSampleBufferGetImageBuffer(buffer) else { continue }
            let t = pts.seconds
            guard sampler.wants(t) else { continue }
            try await sampler.detect(pixels, at: t)
            if let progress, hi > lo { progress(min(1, max(0, (t - lo) / (hi - lo)))) }
        }
        if reader.status == .failed {
            throw FaceAnalysisError.cannotRead(url, reader.error?.localizedDescription ?? "reader failed")
        }
        progress?(1)
        return FaceTrack(samples: sampler.samples)
    }

    /// Picks frames at `samplesPerSecond` from a decoded stream (presentation order) and detects their faces.
    /// Shared by `analyze` and the shared video ingest, so both sample the same frames.
    struct Sampler {
        let interval: Double
        let slack: Double
        let orientation: CGImagePropertyOrientation
        let minConfidence: Double
        let request = DetectFaceRectanglesRequest()
        private var nextSample = -Double.infinity
        private(set) var samples: [FaceSample] = []

        init(_ analyzer: FaceAnalyzer, info: MediaInfo) {
            interval = 1 / max(0.01, analyzer.samplesPerSecond)
            // Half a frame of slack so e.g. 30 fps sampled at 4/s does not drift onto every 8th frame.
            slack = info.frameRate > 0 ? 0.5 / info.frameRate : 0
            orientation = FaceAnalyzer.orientation(rotation: info.rotation, mirrored: info.mirrored)
            minConfidence = analyzer.minConfidence
        }

        /// Whether the frame at `t` is a sample; if so, the next one is due `interval` later.
        mutating func wants(_ t: Double) -> Bool {
            guard t >= nextSample - slack else { return false }
            nextSample = (nextSample.isFinite ? nextSample : t) + interval
            if nextSample < t { nextSample = t + interval }
            return true
        }

        mutating func detect(_ pixels: CVPixelBuffer, at t: Double) async throws {
            let faces = try await request.perform(on: pixels, orientation: orientation)
            if let best = FaceAnalyzer.largest(faces, minConfidence: minConfidence) {
                samples.append(FaceSample(time: t, rect: best.rect, confidence: best.confidence))
            }
        }
    }

    private func analyzeImage(url: URL) async throws -> FaceTrack {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw FaceAnalysisError.cannotRead(url, "unreadable image")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let exif = (props?[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
        let faces = try await DetectFaceRectanglesRequest().perform(on: image, orientation: exif)
        guard let best = Self.largest(faces, minConfidence: minConfidence) else { return FaceTrack(samples: []) }
        return FaceTrack(samples: [FaceSample(time: 0, rect: best.rect, confidence: best.confidence)])
    }

    /// Largest face (by area) above `minConfidence`, converted to a top-left-origin rect clamped to the frame.
    static func largest(_ faces: [FaceObservation], minConfidence: Double) -> (rect: NormRect, confidence: Double)? {
        let best = faces
            .filter { Double($0.confidence) >= minConfidence }
            .max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
        guard let best else { return nil }
        return (topLeftRect(best.boundingBox.cgRect), Double(best.confidence))
    }

    /// Vision's normalized rects have a lower-left origin; `NormRect` uses top-left. Clamped to the unit square.
    static func topLeftRect(_ r: CGRect) -> NormRect {
        let x0 = min(max(Double(r.minX), 0), 1), x1 = min(max(Double(r.maxX), 0), 1)
        let y0 = min(max(1 - Double(r.maxY), 0), 1), y1 = min(max(1 - Double(r.minY), 0), 1)
        return NormRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// EXIF orientation describing how stored frames must be transformed for display.
    /// `MediaInfo` semantics (see `Orientation.textureCoordinate`): display = mirror(rotateClockwise(stored)).
    /// Rotating 90° clockwise is EXIF 6 (`.right`); rotate-then-mirror at 90° is a transpose (EXIF 5, `.leftMirrored`)
    /// and at 270° a transverse (EXIF 7, `.rightMirrored`).
    public static func orientation(rotation: Int, mirrored: Bool) -> CGImagePropertyOrientation {
        switch ((rotation % 360) + 360) % 360 {
        case 90: mirrored ? .leftMirrored : .right
        case 180: mirrored ? .downMirrored : .down
        case 270: mirrored ? .rightMirrored : .left
        default: mirrored ? .upMirrored : .up
        }
    }
}
