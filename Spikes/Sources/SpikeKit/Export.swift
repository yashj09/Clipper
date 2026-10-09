import AVFoundation
import VideoToolbox

public enum ExportCodec: Sendable {
    case proRes422HQ, proRes4444, hevc(bitsPerSecond: Int), hevcHW(bitsPerSecond: Int), h264(bitsPerSecond: Int)

    var settings: [String: Any] {
        switch self {
        case .proRes422HQ: [AVVideoCodecKey: AVVideoCodecType.proRes422HQ]
        case .proRes4444: [AVVideoCodecKey: AVVideoCodecType.proRes4444]
        case .hevcHW(let bps): [AVVideoCodecKey: AVVideoCodecType.hevc,
                                AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true],
                                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bps,
                                                                  kVTCompressionPropertyKey_RealTime as String: false,
                                                                  AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String]]
        case .hevc(let bps): [AVVideoCodecKey: AVVideoCodecType.hevc,
                              AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bps]]
        case .h264(let bps): [AVVideoCodecKey: AVVideoCodecType.h264,
                              AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bps,
                                                                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]]
        }
    }
}

/// Export path: AVAssetReaderVideoCompositionOutput (our compositor) → AVAssetWriter.
/// Also captures the raw composited frames at `captureTimes`, before encoding.
public enum Exporter {
    public struct Result: @unchecked Sendable {
        public let url: URL
        public let rawFrames: [CMTime: CVPixelBuffer]
        public let frameCount: Int
        public let seconds: Double
    }

    public static func export(_ scene: BuiltScene, to url: URL, codec: ExportCodec,
                              captureTimes: [CMTime] = []) async throws -> Result {
        try? FileManager.default.removeItem(at: url)
        let start = ContinuousClock.now
        let comp = scene.composition
        let reader = try AVAssetReader(asset: comp)
        let vTracks = try await comp.loadTracks(withMediaType: .video)
        let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: vTracks, videoSettings: Frames.bgra)
        vOut.videoComposition = scene.videoComposition
        reader.add(vOut)
        let aTracks = try await comp.loadTracks(withMediaType: .audio)
        var aOut: AVAssetReaderAudioMixOutput?
        if !aTracks.isEmpty {
            let o = AVAssetReaderAudioMixOutput(audioTracks: aTracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            reader.add(o); aOut = o
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let size = scene.videoComposition.renderSize
        var vs = codec.settings
        vs[AVVideoWidthKey] = Int(size.width); vs[AVVideoHeightKey] = Int(size.height)
        vs[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                         AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                         AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: vs)
        vIn.expectsMediaDataInRealTime = false
        writer.add(vIn)
        var aIn: AVAssetWriterInput?
        if aOut != nil {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000])
            writer.add(i); aIn = i
        }

        guard reader.startReading() else { throw reader.error! }
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)

        let wanted = Set(captureTimes.map { $0.convertScale(600, method: .roundHalfAwayFromZero) })
        let state = Unchecked(CaptureState())
        let r = Unchecked(reader), w = Unchecked(writer)
        let io = Unchecked((vIn, vOut as AVAssetReaderOutput, aIn, aOut as AVAssetReaderOutput?))
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pump(io.value.0, from: io.value.1, label: "video") { sb in
                state.value.frames += 1
                let pts = CMSampleBufferGetPresentationTimeStamp(sb).convertScale(600, method: .roundHalfAwayFromZero)
                if wanted.contains(pts), let px = sb.imageBuffer { state.value.raw[pts] = px }
            } }
            if io.value.2 != nil { group.addTask { await pump(io.value.2!, from: io.value.3!, label: "audio") { _ in } } }
        }
        if r.value.status == .failed { throw r.value.error! }
        await w.value.finishWriting()
        if w.value.status == .failed { throw w.value.error! }
        let secs = (ContinuousClock.now - start).seconds
        // Map raw frames back onto the caller's original CMTime keys.
        var raw: [CMTime: CVPixelBuffer] = [:]
        for t in captureTimes { raw[t] = state.value.raw[t.convertScale(600, method: .roundHalfAwayFromZero)] }
        return Result(url: url, rawFrames: raw, frameCount: state.value.frames, seconds: secs)
    }

    final class CaptureState { var frames = 0; var raw: [CMTime: CVPixelBuffer] = [:] }

    static func pump(_ input: AVAssetWriterInput, from output: AVAssetReaderOutput, label: String,
                     onSample: @escaping (CMSampleBuffer) -> Void) async {
        let i = Unchecked(input), o = Unchecked(output), cb = Unchecked(onSample)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let q = DispatchQueue(label: "export.\(label)")
            i.value.requestMediaDataWhenReady(on: q) {
                while i.value.isReadyForMoreMediaData {
                    guard let sb = o.value.copyNextSampleBuffer() else {
                        i.value.markAsFinished()
                        cont.resume()
                        return
                    }
                    cb.value(sb)
                    i.value.append(sb)
                }
            }
        }
    }
}
