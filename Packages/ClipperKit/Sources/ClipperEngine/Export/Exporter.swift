import AVFoundation
import Accelerate
import ClipperCore
import VideoToolbox

public struct ExportProgress: Sendable {
    public var fraction: Double
    public var framesWritten: Int
    public var framesPerSecond: Double
}

public struct ExportResult: Sendable {
    public var url: URL
    public var sidecars: [URL]
    public var frames: Int
    public var seconds: Double
    /// Gain applied for loudness normalization (dB), if any.
    public var appliedGain: Double?
}

/// Processes interleaved Float32 audio on its way to the encoder (gain, limiting). Stateful and streaming.
public protocol AudioStage: Sendable {
    mutating func process(_ samples: inout [Float], channels: Int)
    /// Delay the stage introduces (frames); output timestamps are shifted back by this to keep A/V sync.
    var latencyFrames: Int { get }
}

extension AudioStage { public var latencyFrames: Int { 0 } }

/// Loudness normalization: constant gain to reach the target, then a true-peak limiter to hold the ceiling.
public struct LoudnessStage: AudioStage {
    var gain: GainStage
    var limiter: TruePeakLimiter
    public init(gainDB: Double, ceilingDBTP: Double, sampleRate: Double = Exporter.audioSampleRate, channels: Int = Exporter.audioChannels) {
        gain = GainStage(dB: gainDB)
        limiter = TruePeakLimiter(sampleRate: sampleRate, channels: channels, ceilingDBTP: ceilingDBTP)
    }
    public mutating func process(_ samples: inout [Float], channels: Int) {
        gain.process(&samples, channels: channels)
        limiter.process(&samples)
    }
    public var latencyFrames: Int { limiter.latencyFrames }
}

/// Renders a timeline to a file through the same compositor as preview:
/// AVAssetReaderVideoCompositionOutput + AVAssetReaderAudioMixOutput → (audio stage) → AVAssetWriter.
public enum Exporter {
    public static let audioSampleRate = 48_000.0
    public static let audioChannels = 2

    /// Renders `timeline` with `preset`. When the preset has a loudness target, the mix is measured first
    /// (BS.1770) and normalized with gain + true-peak limiting during the encode.
    public static func export(_ timeline: Timeline, assets: [AssetID: MediaAsset], preset: ExportPreset, to url: URL,
                              progress: (@Sendable (ExportProgress) -> Void)? = nil) async throws -> ExportResult {
        var stage: (any AudioStage)?
        var applied: Double?
        if let target = preset.loudness,
           let measured = try await measureMix(timeline, assets: assets), measured.integrated > LoudnessMeter.silenceFloor + 1 {
            let g = LoudnessNormalizer.gain(measured: measured, target: target, ceiling: preset.truePeak, limiterAvailable: true)
            stage = LoudnessStage(gainDB: g, ceilingDBTP: preset.truePeak)
            applied = g
        }
        let s = stage, a = applied
        return try await EncodeScheduler.shared.run(.foreground) {
            try await render(timeline, assets: assets, preset: preset, to: url, audioStage: s, appliedGain: a, progress: progress)
        }
    }

    /// Integrated loudness of the timeline's final audio mix (nil when it has no audio).
    public static func measureMix(_ timeline: Timeline, assets: [AssetID: MediaAsset]) async throws -> LoudnessInfo? {
        let built = try await CompositionBuilder.build(timeline, assets: assets)
        let tracks = try await built.composition.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return nil }
        let reader = try AVAssetReader(asset: built.composition)
        reader.timeRange = CMTimeRange(start: .zero, duration: built.duration)
        let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: pcmSettings)
        out.audioMix = built.audioMix
        out.audioTimePitchAlgorithm = .spectral
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        var meter = LoudnessMeter(sampleRate: audioSampleRate, channels: audioChannels)
        while let sb = out.copyNextSampleBuffer() {
            try Task.checkCancellation()
            meter.process(interleaved: AudioSampleBuffers.floats(sb))
        }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadUnknown) }
        return meter.result()
    }

    static func outputSize(_ timeline: Timeline, _ preset: ExportPreset) -> CGSize {
        CGSize(width: preset.width ?? timeline.canvas.width, height: preset.height ?? timeline.canvas.height)
    }

    private static func render(_ timeline: Timeline, assets: [AssetID: MediaAsset], preset: ExportPreset, to url: URL,
                               audioStage: (any AudioStage)?, appliedGain: Double?,
                               progress: (@Sendable (ExportProgress) -> Void)?) async throws -> ExportResult {
        let start = ContinuousClock.now
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let size = outputSize(timeline, preset)
        let built = try await CompositionBuilder.build(timeline, assets: assets,
                                                       options: BuildOptions(transparent: preset.transparentBackground, outputSize: size))
        let comp = built.composition

        let reader = try AVAssetReader(asset: comp)
        reader.timeRange = CMTimeRange(start: .zero, duration: built.duration)
        let videoOut = AVAssetReaderVideoCompositionOutput(videoTracks: try await comp.loadTracks(withMediaType: .video), videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        videoOut.videoComposition = built.videoComposition
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)
        let audioTracks = try await comp.loadTracks(withMediaType: .audio)
        var audioOut: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let o = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: pcmSettings)
            o.audioMix = built.audioMix
            o.audioTimePitchAlgorithm = .spectral
            reader.add(o)
            audioOut = o
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: preset.container == .mp4 ? .mp4 : .mov)
        writer.shouldOptimizeForNetworkUse = preset.container == .mp4
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings(preset, size: size, fps: timeline.canvas.frameRate))
        videoIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)
        var audioIn: AVAssetWriterInput?
        if audioOut != nil {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: audioSampleRate,
                AVNumberOfChannelsKey: audioChannels, AVEncoderBitRateKey: preset.audioBitrate])
            i.expectsMediaDataInRealTime = false
            writer.add(i)
            audioIn = i
        }

        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        let total = built.duration.seconds
        let counter = FrameCounter()
        let io = UncheckedSendable((videoIn, videoOut as AVAssetReaderOutput, audioIn, audioOut as AVAssetReaderOutput?))
        let stage = UncheckedSendable(StageBox(audioStage))
        let rw = UncheckedSendable((reader, writer))
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await pump(io.value.0, from: io.value.1, label: "video") { sb in
                        let n = counter.increment()
                        if n % 15 == 0, let progress {
                            let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                            let el = (ContinuousClock.now - start).seconds
                            progress(ExportProgress(fraction: min(t / max(total, 0.001), 1), framesWritten: n, framesPerSecond: Double(n) / max(el, 0.001)))
                        }
                        return sb
                    }
                }
                if let aIn = io.value.2, let aOut = io.value.3 {
                    group.addTask {
                        await pump(aIn, from: aOut, label: "audio") { sb in stage.value.apply(sb) }
                    }
                }
            }
        } onCancel: {
            rw.value.0.cancelReading()
            rw.value.1.cancelWriting()
        }
        try Task.checkCancellation()
        if reader.status == .failed { writer.cancelWriting(); throw reader.error ?? CocoaError(.fileReadUnknown) }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }

        var sidecars: [URL] = []
        let base = url.deletingPathExtension()
        for format in preset.sidecars where !Subtitles.cues(timeline).isEmpty {
            let file = base.appendingPathExtension(format.rawValue)
            try (format == .srt ? Subtitles.srt(timeline) : Subtitles.vtt(timeline)).write(to: file, atomically: true, encoding: .utf8)
            sidecars.append(file)
        }
        progress?(ExportProgress(fraction: 1, framesWritten: counter.value, framesPerSecond: Double(counter.value) / (ContinuousClock.now - start).seconds))
        return ExportResult(url: url, sidecars: sidecars, frames: counter.value, seconds: (ContinuousClock.now - start).seconds, appliedGain: appliedGain)
    }

    nonisolated(unsafe) public static let pcmSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        AVSampleRateKey: audioSampleRate, AVNumberOfChannelsKey: audioChannels,
    ]

    static func videoSettings(_ preset: ExportPreset, size: CGSize, fps: FrameRate) -> [String: Any] {
        var s: [String: Any] = [AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)]
        var props: [String: Any] = [:]
        if let mbps = preset.videoBitrate, !preset.codec.isProRes { props[AVVideoAverageBitRateKey] = Int(mbps * 1_000_000) }
        let keyInterval = Int((fps.fps * 2).rounded())   // keyframe every 2 s: good seeking, platform-friendly
        switch preset.codec {
        case .h264:
            s[AVVideoCodecKey] = AVVideoCodecType.h264
            props[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            props[AVVideoMaxKeyFrameIntervalKey] = keyInterval
        case .hevc:
            s[AVVideoCodecKey] = AVVideoCodecType.hevc
            props[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
            props[AVVideoMaxKeyFrameIntervalKey] = keyInterval
        case .hevcAlpha:
            s[AVVideoCodecKey] = AVVideoCodecType.hevcWithAlpha
            props[kVTCompressionPropertyKey_TargetQualityForAlpha as String] = 0.9
            props[AVVideoMaxKeyFrameIntervalKey] = keyInterval
        case .prores422: s[AVVideoCodecKey] = AVVideoCodecType.proRes422
        case .prores422HQ: s[AVVideoCodecKey] = AVVideoCodecType.proRes422HQ
        case .prores4444: s[AVVideoCodecKey] = AVVideoCodecType.proRes4444
        }
        if !props.isEmpty { s[AVVideoCompressionPropertiesKey] = props }
        s[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        return s
    }

    /// Drains `output` into `input`, transforming each sample buffer.
    static func pump(_ input: AVAssetWriterInput, from output: AVAssetReaderOutput, label: String,
                     transform: @escaping @Sendable (CMSampleBuffer) -> CMSampleBuffer?) async {
        let i = UncheckedSendable(input), o = UncheckedSendable(output)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let queue = DispatchQueue(label: "clipper.export.\(label)", qos: .userInitiated)
            i.value.requestMediaDataWhenReady(on: queue) {
                while i.value.isReadyForMoreMediaData {
                    guard let sb = o.value.copyNextSampleBuffer() else {
                        i.value.markAsFinished()
                        cont.resume()
                        return
                    }
                    if let out = transform(sb), !i.value.append(out) {
                        i.value.markAsFinished()
                        cont.resume()
                        return
                    }
                }
            }
        }
    }
}

final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() -> Int { lock.withLock { n += 1; return n } }
    var value: Int { lock.withLock { n } }
}

/// Holds the (mutable, stateful) audio stage; only touched from the audio pump's serial queue.
final class StageBox: @unchecked Sendable {
    var stage: (any AudioStage)?
    init(_ stage: (any AudioStage)?) { self.stage = stage }

    func apply(_ sb: CMSampleBuffer) -> CMSampleBuffer? {
        guard stage != nil else { return sb }
        let shift = CMTime(value: CMTimeValue(stage!.latencyFrames), timescale: CMTimeScale(Exporter.audioSampleRate))
        return AudioSampleBuffers.map(sb, channels: Exporter.audioChannels, shiftBack: shift) { samples in
            stage!.process(&samples, channels: Exporter.audioChannels)
        }
    }
}

/// Helpers for interleaved Float32 LPCM sample buffers.
public enum AudioSampleBuffers {
    public static func floats(_ sb: CMSampleBuffer) -> [Float] {
        guard let block = CMSampleBufferGetDataBuffer(sb) else { return [] }
        let length = CMBlockBufferGetDataLength(block)
        var out = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
        out.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
        return out
    }

    /// Returns a new sample buffer with the same format/timing and transformed samples.
    public static func map(_ sb: CMSampleBuffer, channels: Int, shiftBack: CMTime = .zero, _ body: (inout [Float]) -> Void) -> CMSampleBuffer? {
        var samples = floats(sb)
        body(&samples)
        guard let format = CMSampleBufferGetFormatDescription(sb) else { return nil }
        let bytes = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        var out: CMSampleBuffer?
        let frames = CMSampleBufferGetNumSamples(sb)
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                                                                   sampleCount: frames, presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sb) - shiftBack,
                                                                   packetDescriptions: nil, sampleBufferOut: &out) == noErr else { return nil }
        return out
    }
}

/// Constant gain in dB (the simplest audio stage; loudness normalization builds on it).
public struct GainStage: AudioStage {
    public var gain: Float
    public init(dB: Double) { gain = Float(pow(10, dB / 20)) }
    public mutating func process(_ samples: inout [Float], channels: Int) {
        var g = gain
        vDSP_vsmul(samples, 1, &g, &samples, 1, vDSP_Length(samples.count))
    }
}
