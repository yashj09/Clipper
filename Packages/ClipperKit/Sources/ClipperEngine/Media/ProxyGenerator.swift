import AVFoundation
import ClipperCore
import VideoToolbox

/// Lightweight editing copies of heavy media, used by the preview when `ClipperSettings.editing.useProxies` is on.
///
/// A proxy is the same video, smaller: HEVC with its short side at most 720 px, a keyframe every second (Phase 0 S5:
/// frame-accurate seeks drop from ~28 ms on a 1080p60 original to ~4 ms on a proxy), the original's sample timing
/// (variable frame rate stays variable) and its audio copied untouched. Two things must not change, because the
/// compositor keeps using the *original* asset's `MediaInfo` for every frame it gets from the proxy:
/// - orientation: frames stay in the original's natural (stored) orientation and the track keeps its preferred
///   transform, so `info.rotation`/`mirrored` still apply;
/// - colour: HLG/PQ sources stay 10-bit with their BT.2020 tags, so the compositor's own tone mapping (ADR 0006) sees
///   the same signal.
/// Normalized transforms make the switch between proxy and original invisible to layout.
public enum ProxyGenerator {
    public enum ProxyError: Error, CustomStringConvertible {
        case noVideo(URL)
        case failed(String)
        public var description: String {
            switch self {
            case .noVideo(let u): "\(u.lastPathComponent) has no video to make a proxy of"
            case .failed(let why): "Proxy failed: \(why)"
            }
        }
    }

    /// The short side of a proxy, in pixels.
    public static let shortSide = 720
    /// Media longer than this gets a proxy automatically (seeking a long-GOP original is the slow part).
    public static let longMedia = 20.0 * 60

    /// Whether `info` should have a proxy. Automatic: sources beyond 1080p, ProRes (huge files, heavy reads) and long
    /// recordings — the cases Phase 0 found heavy. 1080p clips, HDR ones included, play smoothly from the original.
    public static func wantsProxy(_ info: MediaInfo, policy: ClipperSettings.Editing.ProxyPolicy) -> Bool {
        guard info.kind == .video, info.naturalWidth > 0, info.naturalHeight > 0 else { return false }
        let short = min(info.naturalWidth, info.naturalHeight)
        guard short > shortSide else { return false }   // already proxy-sized
        switch policy {
        case .never: return false
        case .always: return true
        case .automatic:
            let prores = info.videoCodec.map { $0.hasPrefix("ap") } ?? false   // apcn, apch, ap4h, ap4x, apco, apcs
            return short > 1080 || prores || info.duration.seconds > longMedia
        }
    }

    /// Proxy frame size in the original's natural orientation: the short side scaled to `shortSide`, even dimensions.
    public static func size(for info: MediaInfo) -> (width: Int, height: Int) {
        let w = Double(info.naturalWidth), h = Double(info.naturalHeight)
        let k = min(1, Double(shortSide) / min(w, h))
        func even(_ v: Double) -> Int { max(2, Int((v * k / 2).rounded()) * 2) }
        return (even(w), even(h))
    }

    /// Writes a proxy of `source` to `url` (via a `.partial` file, so `url` only ever holds a complete proxy). Runs at
    /// background priority on the shared encode scheduler, so exports go first. Cancellable.
    public static func make(source: URL, info: MediaInfo, to url: URL,
                            progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let partial = url.deletingPathExtension().appendingPathExtension("partial.mov")
        try? FileManager.default.removeItem(at: partial)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try await EncodeScheduler.shared.run(.background) {
                try await encode(source: source, info: info, to: partial, progress: progress)
            }
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            try FileManager.default.moveItem(at: partial, to: url)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    private static func encode(source: URL, info: MediaInfo, to url: URL, progress: (@Sendable (Double) -> Void)?) async throws {
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw ProxyError.noVideo(source) }
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        let transform = try await video.load(.preferredTransform)
        let sourceFormat = try await video.load(.formatDescriptions).first
        let hdr = info.transfer != .sdr

        let reader = try AVAssetReader(asset: asset)
        let videoOut = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                                                            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)
        var audioOut: AVAssetReaderTrackOutput?
        var audioHint: CMFormatDescription?
        if let audio {
            let o = AVAssetReaderTrackOutput(track: audio, outputSettings: nil)   // passthrough: no re-encode
            o.alwaysCopiesSampleData = false
            reader.add(o)
            audioOut = o
            audioHint = try await audio.load(.formatDescriptions).first
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let (w, h) = size(for: info)
        let fps = max(1, info.frameRate.rounded())
        var compression: [String: Any] = [
            AVVideoMaxKeyFrameIntervalKey: Int(fps),             // a keyframe every second: fast scrubbing
            AVVideoAllowFrameReorderingKey: false,               // no B-frames: any frame decodes from its keyframe forward
            AVVideoAverageBitRateKey: hdr ? 6_000_000 : 4_000_000,
        ]
        compression[AVVideoProfileLevelKey] = hdr ? kVTProfileLevel_HEVC_Main10_AutoLevel as String : kVTProfileLevel_HEVC_Main_AutoLevel as String
        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
            AVVideoCompressionPropertiesKey: compression,
        ]
        if let tags = colorProperties(of: sourceFormat, transfer: info.transfer) { settings[AVVideoColorPropertiesKey] = tags }
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoIn.expectsMediaDataInRealTime = false
        videoIn.transform = transform
        writer.add(videoIn)
        var audioIn: AVAssetWriterInput?
        if audioOut != nil {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioHint)
            i.expectsMediaDataInRealTime = false
            writer.add(i)
            audioIn = i
        }

        guard reader.startReading() else { throw reader.error ?? ProxyError.failed("can't read \(source.lastPathComponent)") }
        guard writer.startWriting() else { throw writer.error ?? ProxyError.failed("can't write the proxy") }
        writer.startSession(atSourceTime: .zero)

        let total = max(info.duration.seconds, 0.001)
        let io = UncheckedSendable((videoIn, videoOut as AVAssetReaderOutput, audioIn, audioOut as AVAssetReaderOutput?))
        let rw = UncheckedSendable((reader, writer))
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    let frames = FrameCounter()
                    await Exporter.pump(io.value.0, from: io.value.1, label: "proxy.video") { sb in
                        if frames.increment() % 30 == 0 { progress?(min(1, CMSampleBufferGetPresentationTimeStamp(sb).seconds / total)) }
                        return sb
                    }
                }
                if let i = io.value.2, let o = io.value.3 {
                    group.addTask { await Exporter.pump(i, from: o, label: "proxy.audio") { $0 } }
                }
            }
        } onCancel: {
            rw.value.0.cancelReading()
        }
        if Task.isCancelled {
            writer.cancelWriting()
            throw CancellationError()
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw reader.error ?? ProxyError.failed("reading \(source.lastPathComponent) failed")
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ProxyError.failed("writing the proxy failed") }
        progress?(1)
    }

    /// Colour tags for the proxy: exactly the source's, so both decode the same way. An untagged source gives an untagged
    /// proxy — AVFoundation then infers the same matrix for both (tagging it Rec.709 would shift the colours of an
    /// untagged SD source, which decodes as BT.601). HDR sources missing tags get BT.2020 + their transfer.
    static func colorProperties(of format: CMFormatDescription?, transfer: TransferFunction) -> [String: String]? {
        func ext(_ key: CFString) -> String? {
            format.flatMap { CMFormatDescriptionGetExtension($0, extensionKey: key) as? String }
        }
        let primaries = ext(kCMFormatDescriptionExtension_ColorPrimaries)
        let function = ext(kCMFormatDescriptionExtension_TransferFunction)
        let matrix = ext(kCMFormatDescriptionExtension_YCbCrMatrix)
        if let primaries, let function, let matrix {
            return [AVVideoColorPrimariesKey: primaries, AVVideoTransferFunctionKey: function, AVVideoYCbCrMatrixKey: matrix]
        }
        switch transfer {
        case .sdr: return nil
        case .hlg:
            return [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020]
        case .pq:
            return [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020, AVVideoTransferFunctionKey: AVVideoTransferFunction_SMPTE_ST_2084_PQ,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020]
        }
    }
}
