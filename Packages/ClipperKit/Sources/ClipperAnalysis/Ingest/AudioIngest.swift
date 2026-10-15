import Accelerate
import AVFoundation
import ClipperCore
import ClipperEngine
import CoreMedia
import Foundation

/// One audio decode of a file, fanned out to every analyzer that needs PCM (Phase 0 finding #3: decoding is the
/// scarce resource for long media).
///
/// - Decode: `AVAssetReader` at the native sample rate (never AVAssetReader resampling: it clicks), in blocks of
///   `blockFrames`. When the meter needs the original channels (one track, mono or stereo) the file is decoded once in
///   its own layout and downmixed here with AVFoundation's own coefficients (stereo → mono = 0.7071·(L + R), measured);
///   otherwise the mono mix comes straight from `AVAssetReaderAudioMixOutput`, exactly as `AudioReader` does.
/// - Fan-out: each consumer runs on its own serial queue with a few blocks in flight; the decoder waits when a
///   consumer is behind, so memory stays bounded and the decode runs at the pace of the slowest consumer.
///   - loudness: `LoudnessMeter` on the native-channel PCM (same as `AudioFileLoudness`);
///   - events: one `SoundEventAnalyzer.Stream` over the whole file (`analyze(url:)` splits long media into chunks
///     read in parallel; the windows are the same grid, so the merged events are equivalent);
///   - 16 kHz branch: one `StreamingResampler` (bit-identical to `Resampler`) feeding the speech envelope and, through
///     a bounded `PCMChannel`, a `PCMStreamTranscriber` (instead of it decoding and resampling the file itself).
/// - Failures: a consumer that throws fails only its own kind; a decode error fails all of them. Cancellation stops
///   the decode and every consumer.
struct AudioIngest {
    struct Request {
        var speech = false
        var loudness = false
        var events: SoundEventAnalyzer?
        var transcriber: (any PCMStreamTranscriber)?
        var locale = Locale(identifier: "en-US")
        var isEmpty: Bool { !speech && !loudness && events == nil && transcriber == nil }
    }

    struct Results {
        var speech: Result<SpeechActivity, Error>?
        var loudness: Result<LoudnessInfo, Error>?
        var events: Result<SoundEvents, Error>?
        var transcript: Result<Transcript, Error>?
    }

    /// Native frames per block handed to consumers (~0.3–1.5 s).
    static let blockFrames = 32_768
    /// Envelope settings shared with `AnalysisPipeline.speechActivity`.
    static let speechRate = 16_000.0
    static let speechHop = 0.01

    /// AVFoundation's stereo → mono downmix coefficient (both channels), measured with `AudioReader.readMono`.
    static let stereoToMono: Float = 0.70710677

    static func run(url: URL, duration: Double, request: Request,
                    eventsProgress: (@Sendable (Double) -> Void)? = nil) async -> Results {
        var results = Results()
        do {
            try await decode(url: url, duration: duration, request: request, eventsProgress: eventsProgress, into: &results)
        } catch {
            if request.speech { results.speech = results.speech ?? .failure(error) }
            if request.loudness { results.loudness = results.loudness ?? .failure(error) }
            if request.events != nil { results.events = results.events ?? .failure(error) }
            if request.transcriber != nil { results.transcript = results.transcript ?? .failure(error) }
        }
        return results
    }

    private static func decode(url: URL, duration: Double, request: Request,
                               eventsProgress: (@Sendable (Double) -> Void)?, into results: inout Results) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw AudioReaderError.noAudioTrack(url) }
        var channels = 0
        var sampleRate = 0.0
        for track in tracks {
            for description in try await track.load(.formatDescriptions) {
                guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { continue }
                channels = max(channels, Int(asbd.mChannelsPerFrame))
                sampleRate = max(sampleRate, asbd.mSampleRate)
            }
        }
        if channels <= 0 { channels = 2 }
        if !(sampleRate >= 8_000 && sampleRate <= 384_000) { sampleRate = 48_000 }

        // Loudness shares the decode only when the downmix can be reproduced exactly; otherwise it reads on its own.
        let wantsMono = request.speech || request.events != nil || request.transcriber != nil
        let ownDownmix = tracks.count == 1 && channels <= 2
        var separateLoudness: Task<LoudnessInfo, Error>?
        if request.loudness, wantsMono, !ownDownmix {
            separateLoudness = Task { try await AudioFileLoudness.measure(url: url) }
        }
        let meterShared = request.loudness && (ownDownmix || !wantsMono)
        let decodeChannels = meterShared ? channels : 1

        // The transcriber says which rate it wants (and installs its model) before the decode starts, so a first-use
        // download doesn't hold the other consumers back mid-stream.
        var transcription: (task: Task<Transcript, Error>, channel: PCMChannel, rate: Double)?
        if let transcriber = request.transcriber {
            do {
                let rate = try await transcriber.streamSampleRate(locale: request.locale)
                let channel = PCMChannel()
                let locale = request.locale
                transcription = (Task { try await transcriber.transcribe(pcm: channel, sampleRate: rate, locale: locale) },
                                 channel, rate)
            } catch {
                results.transcript = .failure(error)
            }
        }

        let sink = Sink(sampleRate: sampleRate, channels: decodeChannels, meter: meterShared, speech: request.speech,
                        events: request.events, duration: duration, eventsProgress: eventsProgress,
                        transcription: transcription.map { ($0.channel, $0.rate) })
        if let events = request.events {
            do { try sink.startEvents(events) } catch { results.events = .failure(error) }
        }

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw AudioReaderError.cannotRead(url, error.localizedDescription) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: decodeChannels,
        ]
        let output: AVAssetReaderOutput = tracks.count == 1 && meterShared
            ? AVAssetReaderTrackOutput(track: tracks[0], outputSettings: settings)
            : AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioReaderError.cannotRead(url, "output not supported") }
        reader.add(output)

        let io = UncheckedSendable((reader, output))
        do {
            try await withTaskCancellationHandler {
                try await withTaskExecutorPreference(DecodeExecutor.shared) {
                    try pump(io.value.0, io.value.1, url: url, into: sink)
                }
            } onCancel: {
                sink.cancel()
            }
        } catch {
            sink.abort(error)
            transcription?.channel.finish(throwing: error)
            transcription?.task.cancel()
            separateLoudness?.cancel()
            if error is CancellationError { _ = await transcription?.task.result; throw error }
            if let transcription { results.transcript = await transcription.task.result }
            if let separateLoudness { results.loudness = await separateLoudness.result }
            throw error
        }

        let finished = sink.finish()
        if request.speech { results.speech = finished.speech }
        if meterShared { results.loudness = finished.loudness }
        if request.events != nil, results.events == nil { results.events = finished.events }
        if let transcription {
            transcription.channel.finish()
            results.transcript = await transcription.task.result
        }
        if let separateLoudness { results.loudness = await separateLoudness.result }
        if Task.isCancelled { throw CancellationError() }
    }

    /// Reads the whole stream into `sink` in blocks. Blocking: runs on `DecodeExecutor`.
    private static func pump(_ reader: AVAssetReader, _ output: AVAssetReaderOutput, url: URL, into sink: Sink) throws {
        guard reader.startReading() else {
            throw AudioReaderError.cannotRead(url, reader.error?.localizedDescription ?? "startReading failed")
        }
        defer { if reader.status == .reading { reader.cancelReading() } }
        let channels = sink.channels
        var block: [Float] = []
        block.reserveCapacity((blockFrames + 8192) * channels)
        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled || sink.isCancelled { reader.cancelReading(); throw CancellationError() }
            if sink.startTime == nil {
                let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
                sink.startTime = pts.isNumeric ? pts.seconds : 0
            }
            guard let data = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let count = CMBlockBufferGetDataLength(data) / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            let old = block.count
            block.append(contentsOf: repeatElement(0, count: count))
            let status = block.withUnsafeMutableBufferPointer { dst in
                CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                                           destination: UnsafeMutableRawPointer(dst.baseAddress! + old))
            }
            if status != kCMBlockBufferNoErr { throw AudioReaderError.cannotRead(url, "CMBlockBufferCopyDataBytes failed (\(status))") }
            if block.count >= blockFrames * channels {
                sink.submit(block)
                block.removeAll(keepingCapacity: true)
            }
        }
        if Task.isCancelled || sink.isCancelled { throw CancellationError() }
        if reader.status == .failed {
            throw AudioReaderError.cannotRead(url, reader.error?.localizedDescription ?? "reader failed")
        }
        if !block.isEmpty { sink.submit(block) }
    }
}

// MARK: - Consumers

/// A serial queue with a bounded number of blocks in flight: `submit` waits for a free slot (back-pressure).
/// The first error a job throws is kept and later jobs are skipped.
private final class Worker: @unchecked Sendable {
    private let queue: DispatchQueue
    private let slots: DispatchSemaphore
    private var error: Error?   // touched only on `queue`

    init(_ label: String, depth: Int = 4) {
        queue = DispatchQueue(label: "clipper.ingest.\(label)", qos: .userInitiated)
        slots = DispatchSemaphore(value: depth)
    }

    func submit(_ job: @escaping @Sendable () throws -> Void) {
        slots.wait()
        queue.async {
            defer { self.slots.signal() }
            guard self.error == nil else { return }
            do { try job() } catch { self.error = error }
        }
    }

    /// Waits for every submitted job; returns the first error.
    func drain() -> Error? { queue.sync { error } }

    func fail(_ error: Error) { queue.sync { if self.error == nil { self.error = error } } }
}

/// Where decoded blocks go. `submit`/`finish` are called from the decode thread, `cancel` from anywhere.
private final class Sink: @unchecked Sendable {
    let sampleRate: Double
    let channels: Int
    private let lock = NSLock()
    private var _cancelled = false
    private var _startTime: Double?

    // Loudness (native channels).
    private let meterWorker: Worker?
    private var meter: LoudnessMeter?
    // Events (mono, native rate).
    private var eventsWorker: Worker?
    private var events: (analyzer: SoundEventAnalyzer, stream: SoundEventAnalyzer.Stream)?
    private let duration: Double
    private let eventsProgress: (@Sendable (Double) -> Void)?
    // 16 kHz branch: speech envelope and/or transcriber feed.
    private let speechWorker: Worker?
    private let speechResampler: StreamingResampler?
    private var envelope = RMSAccumulator(sampleRate: AudioIngest.speechRate, hop: AudioIngest.speechHop)
    private let speech: Bool
    private let transcription: (channel: PCMChannel, rate: Double)?
    private var transcriptResampler: StreamingResampler?   // when the transcriber wants another rate than 16 kHz

    init(sampleRate: Double, channels: Int, meter: Bool, speech: Bool, events: SoundEventAnalyzer?, duration: Double,
         eventsProgress: (@Sendable (Double) -> Void)?, transcription: (PCMChannel, Double)?) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.duration = duration
        self.eventsProgress = eventsProgress
        self.speech = speech
        self.transcription = transcription
        meterWorker = meter ? Worker("loudness") : nil
        if meter { self.meter = LoudnessMeter(sampleRate: sampleRate, channels: channels) }
        let needs16k = speech || transcription?.1 == AudioIngest.speechRate
        speechWorker = speech || transcription != nil ? Worker("speech") : nil
        speechResampler = needs16k ? StreamingResampler(from: sampleRate, to: AudioIngest.speechRate) : nil
        if let t = transcription, t.1 != AudioIngest.speechRate { transcriptResampler = StreamingResampler(from: sampleRate, to: t.1) }
    }

    var isCancelled: Bool { lock.withLock { _cancelled } }
    var startTime: Double? {
        get { lock.withLock { _startTime } }
        set { lock.withLock { _startTime = newValue } }
    }

    func cancel() {
        lock.withLock { _cancelled = true }
        transcription?.channel.finish(throwing: CancellationError())
        transcription?.channel.close()   // unblocks a `send` waiting for the transcriber
    }

    func startEvents(_ analyzer: SoundEventAnalyzer) throws {
        let total = max(duration, 0.001), report = eventsProgress
        guard let stream = try analyzer.makeStream(sampleRate: sampleRate, progress: { report?(min(1, $0 / total)) }) else { return }
        events = (analyzer, stream)
        eventsWorker = Worker("events")
    }

    /// Hands one block (interleaved, `channels`) to every consumer. Blocks while a consumer is behind.
    func submit(_ block: [Float]) {
        let mono = channels == 1 || (eventsWorker == nil && speechWorker == nil) ? block : Self.downmix(block, channels: channels)
        if let meterWorker {
            meterWorker.submit { [self] in block.withUnsafeBufferPointer { meter!.process(interleaved: $0) } }
        }
        if let eventsWorker, let stream = events?.stream {
            eventsWorker.submit { try mono.withUnsafeBufferPointer { try stream.feed($0) } }
        }
        if let speechWorker {
            speechWorker.submit { [self] in
                if let speechResampler {
                    let pcm = mono.withUnsafeBufferPointer { speechResampler.push($0) }
                    deliver16k(pcm)
                }
                if let transcriptResampler, let transcription {
                    transcription.channel.send(mono.withUnsafeBufferPointer { transcriptResampler.push($0) })
                }
            }
        }
    }

    private func deliver16k(_ pcm: [Float]) {
        if speech { envelope.append(pcm) }
        if let transcription, transcriptResampler == nil { transcription.channel.send(pcm) }
    }

    /// Stops consumers after a decode failure or cancellation (their partial state is discarded).
    func abort(_ error: Error) {
        meterWorker?.fail(error)
        eventsWorker?.fail(error)
        speechWorker?.fail(error)
    }

    /// Waits for the consumers and returns their results.
    func finish() -> AudioIngest.Results {
        var r = AudioIngest.Results()
        if let meterWorker {
            if let error = meterWorker.drain() { r.loudness = .failure(error) } else { r.loudness = .success(meter!.result()) }
        }
        if let eventsWorker, let (analyzer, stream) = events {
            if let error = eventsWorker.drain() {
                r.events = .failure(error)
            } else {
                r.events = Result { try analyzer.events(from: try stream.finish(), base: startTime ?? 0, duration: duration) }
            }
        } else if events == nil, eventsWorker == nil {
            r.events = .success(SoundEvents(events: []))   // nothing to watch for
        }
        if let speechWorker {
            speechWorker.submit { [self] in
                if let speechResampler { deliver16k(speechResampler.finish()) }
                if let transcriptResampler, let transcription { transcription.channel.send(transcriptResampler.finish()) }
            }
            if let error = speechWorker.drain() {
                r.speech = .failure(error)
            } else {
                r.speech = .success(SpeechActivityDetector().detect(envelope.envelope))
            }
            transcription?.channel.startTime = startTime ?? 0
        }
        return r
    }

    /// Mono mix of interleaved stereo, as AVFoundation's mixer produces it.
    static func downmix(_ block: [Float], channels: Int) -> [Float] {
        precondition(channels == 2)
        let frames = block.count / 2
        var mono = [Float](repeating: 0, count: frames)
        var k = AudioIngest.stereoToMono
        block.withUnsafeBufferPointer { src in
            mono.withUnsafeMutableBufferPointer { dst in
                vDSP_vsmsma(src.baseAddress!, 2, &k, src.baseAddress! + 1, 2, &k, dst.baseAddress!, 1, vDSP_Length(frames))
            }
        }
        return mono
    }
}

/// `Envelope.rms` over a stream: whole hops only, the remainder carried into the next push, so the result equals
/// `Envelope.rms` of the concatenated samples.
struct RMSAccumulator {
    let sampleRate: Double
    let hop: Double
    let hopSamples: Int
    private var carry: [Float] = []
    private(set) var values: [Float] = []

    init(sampleRate: Double, hop: Double) {
        self.sampleRate = sampleRate
        self.hop = hop
        hopSamples = max(1, Int((hop * sampleRate).rounded()))
    }

    mutating func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let all = carry.isEmpty ? samples : carry + samples
        let whole = all.count / hopSamples * hopSamples
        if whole > 0 { values += Envelope.rms(samples: Array(all[..<whole]), sampleRate: sampleRate, hop: hop).values }
        carry = Array(all[whole...])
    }

    var envelope: Envelope { Envelope(hop: AudioIngest.speechHop, values: values) }
}
