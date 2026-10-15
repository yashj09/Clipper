import AVFoundation
import ClipperCore
import ClipperEngine
import CoreMedia
import Foundation
import Speech

/// On-device transcription with `SpeechAnalyzer` + `SpeechTranscriber` (S3: WER ≈1%, 48–64× realtime on clean
/// speech; end times run early, so the pipeline snaps them afterwards).
///
/// Works on audio and video files: the audio track(s) are decoded by `AVAssetReader` straight into the analyzer's
/// preferred PCM format and streamed buffer by buffer (`analyzeSequence(_:)`), so long recordings need neither a temp
/// file nor the whole waveform in memory. The analyzer pulls buffers, which gives natural back-pressure.
/// Downloads the on-device model for the locale through `AssetInventory` the first time it is needed.
public struct AppleTranscriber: PCMStreamTranscriber {
    public var id: String { "apple" }

    public init() {}

    /// The transcriber module for `locale`, its on-device assets installed, and the audio format it wants.
    private func prepare(_ locale: Locale) async throws -> (SpeechTranscriber, Locale, AVAudioFormat) {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.unavailable("SpeechTranscriber is not available on this device") }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionError.unsupportedLocale(locale.identifier)
        }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionError.unavailable("no audio format compatible with SpeechTranscriber")
        }
        try Task.checkCancellation()
        return (transcriber, supported, format)
    }

    public func streamSampleRate(locale: Locale) async throws -> Double {
        try await prepare(locale).2.sampleRate
    }

    /// Shared-ingest input: mono Float32 at `sampleRate` (the analyzer format's rate), converted to the analyzer's
    /// sample format here (no rate change).
    public func transcribe(pcm: PCMChannel, sampleRate: Double, locale: Locale) async throws -> Transcript {
        let (transcriber, supported, format) = try await prepare(locale)
        guard format.sampleRate == sampleRate, format.channelCount == 1 else {
            pcm.close()
            throw TranscriptionError.failed("stream is \(sampleRate) Hz mono; the analyzer wants \(format)")
        }
        let input = try ChannelInputSequence(channel: pcm, format: format)
        do {
            var words = try await run(transcriber, input: input, onCancel: { pcm.close() })
            pcm.close()
            let offset = pcm.startTime
            if offset != 0 { for i in words.indices { words[i].start += offset; words[i].end += offset } }
            words.sort { $0.start < $1.start }
            return Transcript(locale: supported.identifier(.bcp47), engine: id, words: Fillers.markFillers(words))
        } catch {
            pcm.close()
            throw error
        }
    }

    /// Runs the analyzer over `input` and collects the words (times relative to the first sample).
    private func run<Input: AsyncSequence & Sendable>(_ transcriber: SpeechTranscriber, input: Input,
                                                     onCancel: @escaping @Sendable () -> Void) async throws -> [TranscriptWord]
    where Input.Element == AnalyzerInput {
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let results = transcriber.results
        let collector = Task {
            var words: [TranscriptWord] = []
            for try await result in results {
                let text = result.text
                for run in text.runs {
                    guard let timeRange = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] else { continue }
                    let token = String(text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !token.isEmpty else { continue }
                    let confidence = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self]
                    let start = timeRange.start.seconds
                    let end = start + max(0, timeRange.duration.seconds)
                    words += WordSplitter.split(token, start: start, end: end, confidence: confidence)
                }
            }
            return words
        }
        do {
            let heardAudio = try await withTaskCancellationHandler {
                if let last = try await analyzer.analyzeSequence(input) {
                    try await analyzer.finalizeAndFinish(through: last)
                    return true
                }
                await analyzer.cancelAndFinishNow()
                return false
            } onCancel: {
                onCancel()
            }
            try Task.checkCancellation()
            // With no audio at all the results stream is not guaranteed to end; there is nothing to collect anyway.
            if !heardAudio { collector.cancel(); return [] }
        } catch {
            onCancel()
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            throw error
        }
        let words = collector
        return try await withTaskCancellationHandler { try await words.value } onCancel: { words.cancel() }
    }

    public func transcribe(url: URL, locale: Locale, range: ClosedRange<Double>? = nil) async throws -> Transcript {
        let (transcriber, supported, format) = try await prepare(locale)
        let source = try await PCMStreamSource(url: url, format: format, range: range)
        let words: [TranscriptWord]
        do {
            words = try await run(transcriber, input: PCMInputSequence(source: source), onCancel: { source.cancel() })
            if let error = source.error { throw error }
        } catch {
            source.cancel()
            throw error
        }
        let offset = source.startTime ?? range?.lowerBound ?? 0
        var shifted = words
        if offset != 0 {
            for i in shifted.indices { shifted[i].start += offset; shifted[i].end += offset }
        }
        shifted.sort { $0.start < $1.start }
        return Transcript(locale: supported.identifier(.bcp47), engine: id, words: Fillers.markFillers(shifted))
    }
}

// MARK: - Streaming PCM input

/// Pull-based decoder: each `next()` reads one sample buffer from an `AVAssetReader` (all audio tracks mixed, in the
/// analyzer's format) and wraps it as an `AVAudioPCMBuffer`.
/// `AVAssetReader` is not thread-safe; every access goes through `lock`, which makes the `@unchecked Sendable` sound.
final class PCMStreamSource: @unchecked Sendable {
    private let lock = NSLock()
    private let reader: AVAssetReader
    private let output: AVAssetReaderOutput
    private let bufferFormat: AVAudioFormat
    private let url: URL
    private var cancelled = false
    private var _startTime: Double?
    private var _error: Error?

    init(url: URL, format: AVAudioFormat, range: ClosedRange<Double>?) async throws {
        self.url = url
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw AudioReaderError.noAudioTrack(url) }
        do { reader = try AVAssetReader(asset: asset) } catch {
            throw AudioReaderError.cannotRead(url, error.localizedDescription)
        }
        let asbd = format.streamDescription.pointee
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let channels = Int(max(1, format.channelCount))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: Int(asbd.mBitsPerChannel),
            AVLinearPCMIsFloatKey: isFloat,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: channels,
        ]
        // Interleaved samples from the reader; for mono that is the same memory layout as the analyzer's format.
        if channels == 1 || format.isInterleaved {
            bufferFormat = format
        } else if let f = AVAudioFormat(commonFormat: format.commonFormat, sampleRate: format.sampleRate,
                                        channels: AVAudioChannelCount(channels), interleaved: true) {
            bufferFormat = f
        } else {
            throw AudioReaderError.cannotRead(url, "unsupported analyzer format \(format)")
        }
        let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { throw AudioReaderError.cannotRead(url, "PCM output not supported") }
        reader.add(out)
        output = out
        if let range {
            let lo = max(0, range.lowerBound), hi = max(lo, range.upperBound)
            reader.timeRange = CMTimeRange(start: CMTime(seconds: lo, preferredTimescale: 1_000_000),
                                           duration: CMTime(seconds: hi - lo, preferredTimescale: 1_000_000))
        }
        guard reader.startReading() else {
            throw AudioReaderError.cannotRead(url, reader.error?.localizedDescription ?? "startReading failed")
        }
    }

    /// Presentation time (seconds) of the first decoded sample; analyzer times are relative to it.
    var startTime: Double? { lock.withLock { _startTime } }
    /// A decode error that ended the stream early.
    var error: Error? { lock.withLock { _error } }

    func cancel() {
        lock.withLock {
            guard !cancelled else { return }
            cancelled = true
            if reader.status == .reading { reader.cancelReading() }
        }
    }

    func next() -> AnalyzerInput? {
        lock.withLock {
            while !cancelled {
                guard let sample = output.copyNextSampleBuffer() else {
                    if reader.status == .failed {
                        _error = AudioReaderError.cannotRead(url, reader.error?.localizedDescription ?? "reader failed")
                    }
                    return nil
                }
                let frames = CMSampleBufferGetNumSamples(sample)
                guard frames > 0,
                      let pcm = AVAudioPCMBuffer(pcmFormat: bufferFormat, frameCapacity: AVAudioFrameCount(frames))
                else { continue }
                pcm.frameLength = AVAudioFrameCount(frames)
                let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames),
                                                                          into: pcm.mutableAudioBufferList)
                guard status == noErr else {
                    _error = AudioReaderError.cannotRead(url, "PCM copy failed (\(status))")
                    reader.cancelReading()
                    return nil
                }
                if _startTime == nil {
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                    _startTime = pts.isNumeric ? pts.seconds : nil
                }
                return AnalyzerInput(buffer: pcm)
            }
            return nil
        }
    }
}

struct PCMInputSequence: AsyncSequence, Sendable {
    typealias Element = AnalyzerInput
    let source: PCMStreamSource

    struct AsyncIterator: AsyncIteratorProtocol {
        let source: PCMStreamSource
        mutating func next() async throws -> AnalyzerInput? {
            if Task.isCancelled { source.cancel() }
            let source = source
            // Decoding blocks; keep it off the cooperative pool (see DecodeExecutor).
            return try await offCooperativePool { source.next() }
        }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(source: source) }
}

/// Shared-ingest input: chunks of mono Float32 from a `PCMChannel`, converted to the analyzer's sample format at the
/// same rate (Int16 or Float; the rate already matches, so no resampling happens here).
struct ChannelInputSequence: AsyncSequence, Sendable {
    typealias Element = AnalyzerInput
    let channel: PCMChannel
    let converter: UncheckedSendable<AVAudioConverter?>
    let inFormat: UncheckedSendable<AVAudioFormat>
    let outFormat: UncheckedSendable<AVAudioFormat>

    init(channel: PCMChannel, format: AVAudioFormat) throws {
        guard let float = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false)
        else { throw TranscriptionError.failed("unsupported analyzer format \(format)") }
        self.channel = channel
        inFormat = UncheckedSendable(float)
        outFormat = UncheckedSendable(format)
        let same = float == format
        converter = UncheckedSendable(same ? nil : AVAudioConverter(from: float, to: format))
        if !same, converter.value == nil { throw TranscriptionError.failed("cannot convert to \(format)") }
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        let sequence: ChannelInputSequence
        mutating func next() async throws -> AnalyzerInput? {
            guard let chunk = try await sequence.channel.next() else { return nil }
            return try sequence.input(chunk)
        }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(sequence: self) }

    fileprivate func input(_ chunk: [Float]) throws -> AnalyzerInput {
        let n = AVAudioFrameCount(chunk.count)
        guard let floats = AVAudioPCMBuffer(pcmFormat: inFormat.value, frameCapacity: n) else {
            throw TranscriptionError.failed("cannot allocate audio buffer")
        }
        floats.frameLength = n
        chunk.withUnsafeBufferPointer { floats.floatChannelData![0].update(from: $0.baseAddress!, count: chunk.count) }
        guard let converter = converter.value else { return AnalyzerInput(buffer: floats) }
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat.value, frameCapacity: n) else {
            throw TranscriptionError.failed("cannot allocate audio buffer")
        }
        try converter.convert(to: out, from: floats)
        return AnalyzerInput(buffer: out)
    }
}
