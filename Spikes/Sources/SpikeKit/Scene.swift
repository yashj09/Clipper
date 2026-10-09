import AVFoundation

/// A composition plus everything needed to preview or export it with the spike compositor.
public struct BuiltScene: @unchecked Sendable {
    public let composition: AVMutableComposition
    public let videoComposition: AVMutableVideoComposition
    public let duration: CMTime

    public init(composition: AVMutableComposition, videoComposition: AVMutableVideoComposition, duration: CMTime) {
        self.composition = composition; self.videoComposition = videoComposition; self.duration = duration
    }

    @MainActor public func playerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        return item
    }
}

public enum SceneBuilder {
    /// Inserts `seconds` of the first video (and optionally audio) track of `url` at time zero.
    public static func addTrack(_ comp: AVMutableComposition, url: URL, seconds: Double, audio: Bool = false)
        async throws -> CMPersistentTrackID
    {
        let asset = AVURLAsset(url: url)
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600))
        let src = try await asset.loadTracks(withMediaType: .video)[0]
        let dst = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try dst.insertTimeRange(range, of: src, at: .zero)
        if audio, let a = try await asset.loadTracks(withMediaType: .audio).first {
            let ad = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            try ad.insertTimeRange(range, of: a, at: .zero)
        }
        return dst.trackID
    }

    public static func videoComposition(_ comp: AVMutableComposition, size: CGSize, fps: Int32, layers: [Layer],
                                        compositor: SpikeCompositor.Type = SpikeCompositor.self,
                                        hdrWorkingSpace: SourceTransfer? = nil) -> AVMutableVideoComposition {
        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = compositor
        vc.renderSize = size
        vc.frameDuration = CMTime(value: 1, timescale: fps)
        if let hdr = hdrWorkingSpace {
            // Keep sources in their native HDR space so the compositor sees untouched HLG/PQ values.
            // The compositor stamps Rec.709 on its output buffers (it does the tone mapping itself).
            vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_2020
            vc.colorTransferFunction = hdr == .pq ? AVVideoTransferFunction_SMPTE_ST_2084_PQ : AVVideoTransferFunction_ITU_R_2100_HLG
            vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_2020
        } else {
            vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
            vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
            vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        }
        vc.instructions = [SpikeInstruction(timeRange: CMTimeRange(start: .zero, duration: comp.duration), layers: layers)]
        return vc
    }

    /// The S1 scene: a 9:16 short with a background, picture-in-picture, an animated title and word captions.
    public static func shortScene(seconds: Double = 8) async throws -> BuiltScene {
        let comp = AVMutableComposition()
        let bg = try await addTrack(comp, url: Spike.fixture("bg_1080x1920_60.mov"), seconds: seconds, audio: true)
        let pip = try await addTrack(comp, url: Spike.fixture("overlay_1280x720_30.mov"), seconds: seconds)
        let words = "this caption highlights every single word".split(separator: " ").enumerated().map {
            CaptionWord(String($0.element), 1.0 + Double($0.offset) * 0.45, 1.0 + Double($0.offset + 1) * 0.45)
        }
        let layers: [Layer] = [
            Layer(.track(bg), fit: .fill,
                  scale: Track1D([(0, 1.0), (4, 1.15), (8, 1.0)])),                      // slow punch-in
            Layer(.track(pip), fit: .width(0.8),
                  centerX: Track1D([(0, 0.3), (3, 0.7), (6, 0.5)]),
                  centerY: Track1D([(0, 0.25), (6, 0.3)]),
                  scale: Track1D([(0, 0.5), (2, 1.0)]),
                  rotation: Track1D([(0, -0.15), (4, 0.1), (8, 0)]),
                  opacity: Track1D([(0, 0), (0.5, 1)])),
            Layer(.solid(SIMD4(0, 0, 0, 0.55)), centerY: Track1D(0.86), scale: Track1D(0.14)),
            Layer(.text("CLIPPER SPIKE", size: 110), centerY: Track1D(0.1),
                  scale: Track1D([(0, 0.6), (0.6, 1.1), (0.9, 1.0)])),
            Layer(.caption(words, size: 72), centerY: Track1D(0.86)),
        ]
        let vc = videoComposition(comp, size: CGSize(width: 1080, height: 1920), fps: 60, layers: layers)
        return BuiltScene(composition: comp, videoComposition: vc, duration: comp.duration)
    }
}
