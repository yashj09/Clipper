import AVFoundation
import ClipperCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// A frame worth using as a video's cover (thumbnail).
public struct CoverCandidate: Codable, Sendable, Equatable {
    /// Source seconds (`CoverFramePicker`) or timeline seconds (`TimelineCover`).
    public var time: Double
    public var score: Double
    /// What contributed to the score, for display.
    public var reasons: [String]
    /// Vision face capture quality (0…1) of the full-resolution frame, once `refine` found a face in it.
    public var faceQuality: Double?

    public init(time: Double, score: Double, reasons: [String], faceQuality: Double? = nil) {
        self.time = time; self.score = score; self.reasons = reasons; self.faceQuality = faceQuality
    }
}

/// Picks cover frames: a cheap ranking over the `.visual` samples (and `.faces`, when analyzed), then a
/// full-resolution face-quality pass over the best few.
public enum CoverFramePicker {
    /// Score per sample: `sharpness` × its sharpness, plus each of the others when it holds. `refine` adds
    /// `faceQuality` × Vision's capture quality.
    static let weights = (sharpness: 0.4, face: 0.3, exposure: 0.2, subject: 0.1, faceQuality: 0.3)
    /// Mean luma that reads as neither too dark nor blown out.
    static let exposed = 0.15...0.85
    /// Salient-region area (fraction of the frame) that reads as a framed subject rather than noise or the whole frame.
    static let subjectArea = 0.05...0.6
    /// Seconds between any two candidates, so they show different moments.
    static let spacing = 2.0
    /// Seconds skipped at each end (fades, black frames, the camera being lowered).
    static let margin = 0.5

    /// The best `count` sampled moments of a clip, best first.
    public static func candidates(_ analysis: AssetAnalysis, count: Int, duration: Double) -> [CoverCandidate] {
        let samples = analysis.visual?.samples ?? []
        let inside = samples.filter { $0.time >= margin && $0.time <= duration - margin }
        let faceTimes = analysis.faces?.samples.map(\.time) ?? []
        return best((inside.isEmpty ? samples : inside).map { score($0, faceTimes: faceTimes) }, count: count)
    }

    /// The `count` highest-scoring candidates, best first, at least `spacing` apart.
    static func best(_ candidates: [CoverCandidate], count: Int) -> [CoverCandidate] {
        let ranked = candidates.sorted { $0.score != $1.score ? $0.score > $1.score : $0.time < $1.time }
        var picked: [CoverCandidate] = []
        for candidate in ranked where picked.count < count {
            if picked.allSatisfy({ abs($0.time - candidate.time) >= spacing }) { picked.append(candidate) }
        }
        return picked
    }

    static func score(_ sample: VisualSample, faceTimes: [Double]) -> CoverCandidate {
        let sharpness = sample.sharpness ?? 0
        var score = weights.sharpness * sharpness
        var reasons = [String(format: "sharpness %.2f", sharpness)]
        if faceTimes.contains(where: { abs($0 - sample.time) <= 0.5 }) {
            score += weights.face
            reasons.append("face")
        }
        if let luma = sample.luma {
            if exposed.contains(luma) {
                score += weights.exposure
                reasons.append("well exposed")
            } else {
                reasons.append(luma < exposed.lowerBound ? "dark" : "bright")
            }
        }
        if let r = sample.salient, subjectArea.contains(r.width * r.height) {
            score += weights.subject
            reasons.append("framed subject")
        }
        return CoverCandidate(time: sample.time, score: score, reasons: reasons)
    }

    /// Scores Vision's face capture quality on each candidate's full-resolution frame and re-ranks. Pass about twice
    /// as many candidates as you will keep, so a frame with a better face can overtake.
    public static func refine(url: URL, candidates: [CoverCandidate]) async throws -> [CoverCandidate] {
        let generator = frameGenerator(AVURLAsset(url: url), maximumSize: .zero)
        let request = DetectFaceCaptureQualityRequest()
        var out = candidates
        for i in out.indices {
            try Task.checkCancellation()
            let image = try await generator.image(at: CMTime(seconds: out[i].time, preferredTimescale: 600)).image
            let faces = try await request.perform(on: image)
            guard let quality = faces.compactMap({ $0.captureQuality.map { Double($0.score) } }).max() else { continue }
            out[i].faceQuality = quality
            out[i].score += weights.faceQuality * quality
            out[i].reasons.append(String(format: "face quality %.2f", quality))
        }
        return out.sorted { $0.score != $1.score ? $0.score > $1.score : $0.time < $1.time }
    }

    /// Writes the frame at `time` as a JPEG at most `maxWidth` pixels wide (display-oriented, SDR).
    public static func export(url: URL, time: Double, to output: URL, maxWidth: Int = 1080) async throws {
        let width = CGFloat(maxWidth)
        let generator = frameGenerator(AVURLAsset(url: url), maximumSize: CGSize(width: width, height: width * 16))
        let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: output.path])
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: output.path]) }
    }

    /// Exact frames (zero tolerance), display-oriented; `.zero` keeps the full size.
    private static func frameGenerator(_ asset: AVAsset, maximumSize: CGSize) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return generator
    }
}
