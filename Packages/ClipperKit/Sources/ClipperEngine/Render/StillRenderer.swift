import AVFoundation
import ClipperCore
import ImageIO
import UniformTypeIdentifiers

/// Single frames of media as the compositor renders them — upright and tone-mapped exactly like the video — for
/// freeze frames.
public enum StillRenderer {
    /// The frame of `asset` at source time `time`, at its display size.
    public static func still(of asset: MediaAsset, at time: RationalTime) async throws -> CGImage {
        let info = asset.info
        let w = max(2, info.displayWidth / 2 * 2), h = max(2, info.displayHeight / 2 * 2)
        let canvas = Canvas(width: w, height: h, frameRate: FrameRate.nearestStandard(to: info.frameRate > 0 ? info.frameRate : 30))
        let frame = canvas.frameRate.frameDuration
        let start = RationalTime.max(.zero, RationalTime.min(time, info.duration - frame))
        let item = Item(range: TimeRange(start: .zero, duration: frame),
                        content: .media(MediaRef(asset: asset.id, source: TimeRange(start: start, duration: frame), useAudio: false)))
        let timeline = Timeline(name: "Still", canvas: canvas, tracks: [Track(kind: .video, items: [item])])
        let built = try await CompositionBuilder.build(timeline, assets: [asset.id: asset])
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: .zero).image
    }

    /// Writes `image` as a JPEG (creating the folder).
    public static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.9) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
    }

    /// Writes `image` as a PNG (creating the folder).
    public static func writePNG(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
    }
}
