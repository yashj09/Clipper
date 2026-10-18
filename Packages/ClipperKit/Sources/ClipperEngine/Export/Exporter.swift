import AVFoundation
import Accelerate
import ClipperCore
import CoreText
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
    /// At the end of the stream: the `latencyFrames` still held back (interleaved), so the end isn't cut off.
    mutating func flush(channels: Int) -> [Float]
}

extension AudioStage {
    public var latencyFrames: Int { 0 }
    public mutating func flush(channels: Int) -> [Float] { [] }
}

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
    public mutating func flush(channels: Int) -> [Float] { limiter.flush() }
}

/// Renders a timeline to a file through the same compositor as preview:
/// AVAssetReaderVideoCompositionOutput + AVAssetReaderAudioMixOutput → (audio stage) → AVAssetWriter.
///
/// A normalised export (preset with a loudness target) needs the whole mix measured before the first sample is
/// encoded. The composition is built once; the measuring pass decodes and mixes the audio once and keeps the mixed
/// PCM in a temporary CAF beside the output (`<name>.partial-mix.caf`, ~23 MB per minute), and the render pass
/// streams the audio from that file through the `LoudnessStage` instead of decoding and mixing everything again.
/// The capture is removed when the export ends, however it ends. Exports without a target stay single-pass.
public enum Exporter {
    public static let audioSampleRate = 48_000.0
    public static let audioChannels = 2

    /// Renders `timeline` with `preset`. When the preset has a loudness target, the mix is measured first
    /// (BS.1770) and normalized with gain + true-peak limiting during the encode.
    public static func export(_ timeline: Timeline, assets: [AssetID: MediaAsset], preset: ExportPreset, to url: URL,
                              progress: (@Sendable (ExportProgress) -> Void)? = nil) async throws -> ExportResult {
        let size = outputSize(timeline, preset)
        let built = try await CompositionBuilder.build(timeline, assets: assets,
                                                       options: BuildOptions(transparent: preset.transparentBackground, outputSize: size))
        var stage: (any AudioStage)?
        var applied: Double?
        var capture: URL?
        defer { if let capture { try? FileManager.default.removeItem(at: capture) } }
        if let target = preset.loudness {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let file = mixCaptureURL(for: url)
            capture = file   // set before measuring, so a failed or cancelled measurement is cleaned up too
            if let measured = try await measureMix(built, capturingTo: file) {
                if measured.integrated > LoudnessMeter.silenceFloor + 1 {
                    let g = LoudnessNormalizer.gain(measured: measured, target: target, ceiling: preset.truePeak, limiterAvailable: true)
                    stage = LoudnessStage(gainDB: g, ceilingDBTP: preset.truePeak)
                    applied = g
                }
            } else {
                capture = nil   // no audio, nothing captured
            }
        }
        let s = stage, a = applied, mix = capture
        return try await EncodeScheduler.shared.run(.foreground) {
            try await render(built, timeline: timeline, preset: preset, to: url, size: size, mixFile: mix,
                             audioStage: s, appliedGain: a, progress: progress)
        }
    }

    /// The frame of `timeline` at `time` as an export renders it (captions, titles, callouts, colour), at most
    /// `maxWidth` pixels wide.
    public static func renderFrame(_ timeline: Timeline, assets: [AssetID: MediaAsset], at time: RationalTime,
                                   maxWidth: Int = 1080) async throws -> CGImage {
        let canvas = timeline.canvas
        let width = max(2, min(maxWidth, canvas.width))
        let height = max(2, Int((Double(canvas.height) * Double(width) / Double(canvas.width)).rounded()))
        let built = try await CompositionBuilder.build(timeline, assets: assets,
                                                       options: BuildOptions(outputSize: CGSize(width: width, height: height)))
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let last = RationalTime.max(.zero, timeline.duration - canvas.frameRate.frameDuration)
        return try await generator.image(at: RationalTime.min(time.floorToFrame(canvas.frameRate), last).cmTime).image
    }

    /// Integrated loudness of the timeline's final audio mix (nil when it has no audio).
    public static func measureMix(_ timeline: Timeline, assets: [AssetID: MediaAsset]) async throws -> LoudnessInfo? {
        try await measureMix(try await CompositionBuilder.build(timeline, assets: assets), capturingTo: nil)
    }

    /// Decodes and mixes the composition's audio once, measuring it and, with `capture`, writing the mixed
    /// 48 kHz stereo Float32 PCM to a CAF whose frame `n` is timeline time `n / 48 kHz` (gaps in the mix output are
    /// filled with silence, overlaps dropped), so the render pass can stream it back with exact A/V sync.
    static func measureMix(_ built: BuiltComposition, capturingTo capture: URL?) async throws -> LoudnessInfo? {
        let tracks = try await built.composition.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return nil }
        let reader = try AVAssetReader(asset: built.composition)
        reader.timeRange = CMTimeRange(start: .zero, duration: built.duration)
        let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: pcmSettings)
        out.audioMix = built.audioMix
        out.audioTimePitchAlgorithm = .spectral
        reader.add(out)
        let writer = try capture.map { try MixCapture.Writer(url: $0) }
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        var meter = LoudnessMeter(sampleRate: audioSampleRate, channels: audioChannels)
        while let sb = out.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); throw CancellationError() }
            let samples = AudioSampleBuffers.floats(sb)
            meter.process(interleaved: samples)
            try writer?.write(samples, at: CMSampleBufferGetPresentationTimeStamp(sb))
        }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadUnknown) }
        writer?.close()
        return meter.result()
    }

    static func outputSize(_ timeline: Timeline, _ preset: ExportPreset) -> CGSize {
        CGSize(width: preset.width ?? timeline.canvas.width, height: preset.height ?? timeline.canvas.height)
    }

    /// Where an export is written until it succeeds: a sibling of `url`, so an existing file at `url` (the last good
    /// export) is only replaced by a complete one.
    static func partialURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("partial").appendingPathExtension(url.pathExtension)
    }

    /// The measured mix of a normalised export, kept beside the partial file until the export ends.
    static func mixCaptureURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("partial-mix").appendingPathExtension("caf")
    }

    private static func render(_ built: BuiltComposition, timeline: Timeline, preset: ExportPreset, to url: URL, size: CGSize,
                               mixFile: URL?, audioStage: (any AudioStage)?, appliedGain: Double?,
                               progress: (@Sendable (ExportProgress) -> Void)?) async throws -> ExportResult {
        let start = ContinuousClock.now
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = partialURL(for: url)
        try? FileManager.default.removeItem(at: partial)
        let frames: Int
        do {
            frames = try await encode(built, timeline: timeline, preset: preset, to: partial, size: size, mixFile: mixFile,
                                      audioStage: audioStage, start: start, progress: progress)
            try install(partial, at: url)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            removeSafeSaveLeftovers(of: partial)
            throw error
        }
        let sidecars = try writeSidecars(timeline, formats: preset.sidecars, besides: url)
        progress?(ExportProgress(fraction: 1, framesWritten: frames, framesPerSecond: Double(frames) / (ContinuousClock.now - start).seconds))
        return ExportResult(url: url, sidecars: sidecars, frames: frames, seconds: (ContinuousClock.now - start).seconds, appliedGain: appliedGain)
    }

    /// Moves the finished file into place, replacing any previous export.
    static func install(_ file: URL, at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: file)
        } else {
            try FileManager.default.moveItem(at: file, to: url)
        }
    }

    /// Encodes the composition to `url`; returns the number of video frames written. Audio comes from `mixFile` (the
    /// measured mix of a normalised export) when given, else straight from the composition's audio mix.
    private static func encode(_ built: BuiltComposition, timeline: Timeline, preset: ExportPreset, to url: URL, size: CGSize,
                               mixFile: URL?, audioStage: (any AudioStage)?, start: ContinuousClock.Instant,
                               progress: (@Sendable (ExportProgress) -> Void)?) async throws -> Int {
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
        var audioOut: (any SampleBufferSource)?
        if let mixFile {
            audioOut = try MixCapture.Reader(url: mixFile)
        } else {
            let audioTracks = try await comp.loadTracks(withMediaType: .audio)
            if !audioTracks.isEmpty {
                let o = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: pcmSettings)
                o.audioMix = built.audioMix
                o.audioTimePitchAlgorithm = .spectral
                reader.add(o)
                audioOut = o
            }
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
        let io = UncheckedSendable((videoIn, videoOut as any SampleBufferSource, audioIn, audioOut))
        let stage = UncheckedSendable(StageBox(audioStage))
        let rw = UncheckedSendable((reader, writer, audioOut as? MixCapture.Reader))
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
                        await pump(aIn, from: aOut, label: "audio", transform: { sb in stage.value.apply(sb) },
                                   finish: { stage.value.tail() })
                    }
                }
            }
        } onCancel: {
            // Stop the sources only: the pumps then see the end of their streams and finish. Cancelling the writer
            // here instead raced the pumps (requestMediaDataWhenReady throws on a cancelled writer, and a pump
            // waiting for readiness was never called again, hanging the export).
            rw.value.0.cancelReading()
            rw.value.2?.cancel()
        }
        if Task.isCancelled { writer.cancelWriting(); throw CancellationError() }
        if reader.status == .failed { writer.cancelWriting(); throw reader.error ?? CocoaError(.fileReadUnknown) }
        if let error = rw.value.2?.error { writer.cancelWriting(); throw error }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        removeSafeSaveLeftovers(of: url)
        return counter.value
    }

    /// Writes subtitle sidecars next to `url`: `<name>.<ext>` for the visible caption tracks and
    /// `<name>.<language>.<ext>` for every language-tagged caption track (hidden ones included).
    @discardableResult
    public static func writeSidecars(_ timeline: Timeline, formats: [SidecarFormat], besides url: URL) throws -> [URL] {
        let dir = url.deletingLastPathComponent(), name = url.deletingPathExtension().lastPathComponent
        return try Subtitles.sidecars(timeline, formats: formats, fontName: fontFullName).map { sidecar in
            let file = dir.appendingPathComponent("\(name).\(sidecar.suffix)")
            try sidecar.contents.write(to: file, atomically: true, encoding: .utf8)
            return file
        }
    }

    /// The full name Core Text resolves a PostScript name to (the font the renderer actually draws with), for ASS styles.
    static func fontFullName(_ postScript: String) -> String {
        CTFontCopyFullName(CTFontCreateWithName(postScript as CFString, 12, nil)) as String
    }

    /// With `shouldOptimizeForNetworkUse` the writer saves via a temporary "<name>.sb-XXXX" sibling and may still be
    /// cleaning it up when `finishWriting` returns; if the process exits right away (CLI) it is left behind.
    static func removeSafeSaveLeftovers(of url: URL) {
        let dir = url.deletingLastPathComponent(), prefix = url.lastPathComponent + ".sb-"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
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

    /// Drains `output` into `input`, transforming each sample buffer; `finish` may supply one last buffer at the end.
    static func pump(_ input: AVAssetWriterInput, from output: any SampleBufferSource, label: String,
                     transform: @escaping @Sendable (CMSampleBuffer) -> CMSampleBuffer?,
                     finish: (@Sendable () -> CMSampleBuffer?)? = nil) async {
        let i = UncheckedSendable(input), o = UncheckedSendable(output)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let queue = DispatchQueue(label: "clipper.export.\(label)", qos: .userInitiated)
            i.value.requestMediaDataWhenReady(on: queue) {
                while i.value.isReadyForMoreMediaData {
                    guard let sb = o.value.copyNextSampleBuffer() else {
                        if let last = finish?() { _ = i.value.append(last) }
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
    /// End of the last input buffer and its format, to place the stage's tail right after it.
    private var end: CMTime?
    private var format: CMFormatDescription?

    init(_ stage: (any AudioStage)?) { self.stage = stage }

    private var shift: CMTime {
        CMTime(value: CMTimeValue(stage?.latencyFrames ?? 0), timescale: CMTimeScale(Exporter.audioSampleRate))
    }

    func apply(_ sb: CMSampleBuffer) -> CMSampleBuffer? {
        guard stage != nil else { return sb }
        let frames = CMSampleBufferGetNumSamples(sb)
        end = CMSampleBufferGetPresentationTimeStamp(sb) + CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(Exporter.audioSampleRate))
        format = CMSampleBufferGetFormatDescription(sb)
        return AudioSampleBuffers.map(sb, channels: Exporter.audioChannels, shiftBack: shift) { samples in
            stage!.process(&samples, channels: Exporter.audioChannels)
        }
    }

    /// The audio the stage still holds back at the end of the stream (its latency), stamped right after the last
    /// buffer it output — without it every limited export loses its last `latencyFrames`.
    func tail() -> CMSampleBuffer? {
        guard stage != nil, let end, let format else { return nil }
        let samples = stage!.flush(channels: Exporter.audioChannels)
        guard !samples.isEmpty else { return nil }
        return AudioSampleBuffers.make(samples, channels: Exporter.audioChannels, format: format, at: end - shift)
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
        return make(samples, channels: channels, format: format, at: CMSampleBufferGetPresentationTimeStamp(sb) - shiftBack)
    }

    /// A sample buffer holding interleaved Float32 `samples` in `format`, starting at `time`.
    public static func make(_ samples: [Float], channels: Int, format: CMFormatDescription, at time: CMTime) -> CMSampleBuffer? {
        guard channels > 0, !samples.isEmpty else { return nil }
        let bytes = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        var out: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                                                                   sampleCount: samples.count / channels, presentationTimeStamp: time,
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
