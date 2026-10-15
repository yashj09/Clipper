import AVFoundation
import ClipperCore
import ClipperEngine
import CoreMedia
import Foundation
import SoundAnalysis
import Synchronization

public enum SoundEventError: Error, Sendable, CustomStringConvertible {
    case unknownLabels([String])
    case cannotRead(URL, String)
    case analysisFailed(String)

    public var description: String {
        switch self {
        case .unknownLabels(let l): "Unknown SoundAnalysis labels: \(l.joined(separator: ", "))"
        case .cannotRead(let url, let why): "Cannot read audio from \(url.lastPathComponent): \(why)"
        case .analysisFailed(let why): "Sound classification failed: \(why)"
        }
    }
}

/// Detects crowd/reaction sounds (laughter, applause, cheering, shouting, …) with Apple's built-in SoundAnalysis
/// classifier (`SNClassifySoundRequest(classifierIdentifier: .version1)`, 303 labels, multi-label confidences).
///
/// - Audio: all audio tracks of any AVFoundation-readable file (audio or video container) are decoded with
///   `AVAssetReader`, mixed to mono **at the source sample rate**, and streamed into `SNAudioStreamAnalyzer`, which
///   resamples internally. Don't let AVFoundation resample: `AVAssetReaderAudioMixOutput` converting 48 kHz AAC to
///   16 kHz inserts clicks at buffer boundaries (~6/s), which the classifier hears as "beep"/"click".
/// - Windows: `windowDuration` (default 1.5 s) with `overlap` (default 0.5 → a 0.75 s hop). Every window in which a
///   watched label reaches `minConfidence` counts; consecutive windows of the same label are merged into one event
///   when the gap between them is ≤ `maxGap` (overlapping windows always merge), keeping the maximum confidence.
///   Event bounds therefore have window resolution (an isolated 0.3 s gasp becomes a ~1.5 s event).
/// - Long media is split into `chunkDuration` pieces analyzed concurrently (`maxConcurrentChunks`), each on its own
///   reader. Chunks are cut on the window hop grid and read one window past their end, so the union of their windows
///   equals a single pass. Decode/classify loops block a thread and run on `DecodeExecutor`.
/// - Times are seconds of the source (a `range` is reported in source time, not relative to its start).
public struct SoundEventAnalyzer: Sendable {
    /// Classifier identifiers for reaction sounds, checked against `SNClassifySoundRequest.knownClassifications`
    /// (classifier `.version1`): laughter (`laughter`, `belly_laugh`, `giggling`, `chuckle_chortle`, `snicker`),
    /// applause (`applause`, `clapping`), `cheering`, shouting (`shout`, `yell`, `screaming`, `battle_cry`),
    /// `crowd`, `booing`, `gasp`. Not included on purpose: `baby_laughter`, `children_shouting`, `chatter`, `babble`
    /// (background talk, too common in streams to signal a highlight).
    public static let defaultLabels: Set<String> = [
        "laughter", "belly_laugh", "giggling", "chuckle_chortle", "snicker",
        "applause", "clapping", "cheering",
        "shout", "yell", "screaming", "battle_cry",
        "crowd", "booing", "gasp",
    ]

    /// Coarse category of a classifier label, for scoring that doesn't care which kind of laugh it was.
    /// Labels outside `defaultLabels` map to themselves.
    public static func category(of label: String) -> String {
        switch label {
        case "laughter", "belly_laugh", "giggling", "chuckle_chortle", "snicker", "baby_laughter": "laughter"
        case "applause", "clapping": "applause"
        case "shout", "yell", "screaming", "battle_cry", "children_shouting": "shouting"
        default: label
        }
    }

    /// Every label the built-in classifier knows.
    public static func knownLabels() throws -> [String] {
        try SNClassifySoundRequest(classifierIdentifier: .version1).knownClassifications
    }

    public var labels: Set<String>
    public var minConfidence: Double = 0.5
    /// Classifier window in seconds (clamped to the classifier's supported range, 0.5…15 s).
    public var windowDuration: Double = 1.5
    /// Fraction of a window shared with the next one, 0 ≤ overlap < 1.
    public var overlap: Double = 0.5
    /// Same-label windows closer than this (seconds) merge into one event.
    public var maxGap: Double = 0.6
    /// Media longer than this is split into chunks of about this many seconds, analyzed concurrently.
    public var chunkDuration: Double = 600
    public var maxConcurrentChunks: Int = 4

    public init(labels: Set<String> = SoundEventAnalyzer.defaultLabels, minConfidence: Double = 0.5) {
        self.labels = labels
        self.minConfidence = minConfidence
    }

    /// - Parameter progress: fraction 0…1 of the (range of the) audio classified so far.
    public func analyze(url: URL, range: ClosedRange<Double>? = nil,
                        progress: (@Sendable (Double) -> Void)? = nil) async throws -> SoundEvents {
        guard !labels.isEmpty else { progress?(1); return SoundEvents(events: []) }
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        let unknown = labels.subtracting(request.knownClassifications)
        if !unknown.isEmpty { throw SoundEventError.unknownLabels(unknown.sorted()) }
        let window = Self.clampedWindow(windowDuration, constraint: request.windowDurationConstraint)
        let overlap = min(max(overlap, 0), 0.95)
        let hop = window * (1 - overlap)

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw AudioReaderError.noAudioTrack(url) }
        var sampleRate = 0.0
        for track in tracks {
            for desc in try await track.load(.formatDescriptions) {
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
                    sampleRate = max(sampleRate, asbd.mSampleRate)
                }
            }
        }
        if !(sampleRate >= 8_000 && sampleRate <= 384_000) { sampleRate = 48_000 }
        let duration = try await asset.load(.duration).seconds

        let lo = max(0, range?.lowerBound ?? 0)
        let hi = min(range?.upperBound ?? duration, duration.isFinite && duration > 0 ? duration : .infinity)
        guard hi.isFinite, hi - lo >= window else { progress?(1); return SoundEvents(events: []) }

        // Chunks start on the hop grid so their windows line up with a single pass over [lo, hi].
        let hopsPerChunk = max(1, (chunkDuration / hop).rounded(.down))
        let chunkLength = hopsPerChunk * hop
        var chunks: [(start: Double, keepBefore: Double, readEnd: Double)] = []
        var a = lo
        while a < hi - window + 1e-9 {
            let b = a + chunkLength
            let last = b >= hi - window
            chunks.append((a, last ? .infinity : b, last ? hi : min(hi, b + window)))
            if last { break }
            a = b
        }

        let config = ChunkConfig(url: url, labels: labels, minConfidence: minConfidence, window: window,
                                 overlap: overlap, sampleRate: sampleRate)
        let fed = Mutex([Double](repeating: 0, count: chunks.count))
        let total = hi - lo
        let report: (@Sendable (Int, Double) -> Void)? = progress.map { p in
            { @Sendable index, seconds in
                let sum = fed.withLock { $0[index] = seconds; return $0.reduce(0, +) }
                p(min(1, sum / total))
            }
        }
        let limit = max(1, maxConcurrentChunks)
        let audioTracks = UncheckedSendable(tracks)   // immutable after loading; each chunk only reads them
        let windows = try await withThrowingTaskGroup(of: [Window].self, returning: [Window].self) { group in
            var all: [Window] = []
            for (i, chunk) in chunks.enumerated() {
                if i >= limit, let done = try await group.next() { all += done }
                group.addTask(executorPreference: DecodeExecutor.shared) {
                    try Self.classify(config, asset: asset, tracks: audioTracks.value, from: chunk.start, to: chunk.readEnd,
                                      keepBefore: chunk.keepBefore) { report?(i, $0) }
                }
            }
            for try await done in group { all += done }
            return all
        }
        progress?(1)
        return SoundEvents(events: Self.merge(windows, minConfidence: minConfidence, maxGap: maxGap))
    }

    // MARK: - Merging

    /// One classifier window: source-time bounds and the confidences of watched labels.
    struct Window: Sendable, Equatable {
        var start: Double
        var end: Double
        var scores: [String: Double]
    }

    /// Per label, consecutive windows at or above `minConfidence` whose gap is ≤ `maxGap` become one event spanning
    /// them, with the maximum confidence. Events are sorted by start, then label.
    static func merge(_ windows: [Window], minConfidence: Double, maxGap: Double) -> [SoundEvent] {
        let sorted = windows.sorted { $0.start < $1.start }
        var open: [String: SoundEvent] = [:]
        var events: [SoundEvent] = []
        for w in sorted {
            for (label, confidence) in w.scores where confidence >= minConfidence {
                if var e = open[label], w.start - e.end <= maxGap {
                    e.end = max(e.end, w.end)
                    e.confidence = max(e.confidence, confidence)
                    open[label] = e
                } else {
                    if let e = open[label] { events.append(e) }
                    open[label] = SoundEvent(label: label, start: w.start, end: w.end, confidence: confidence)
                }
            }
        }
        events += open.values
        return events.sorted { ($0.start, $0.label) < ($1.start, $1.label) }
    }

    // MARK: - Classification

    fileprivate struct ChunkConfig: Sendable {
        var url: URL
        var labels: Set<String>
        var minConfidence: Double
        var window: Double
        var overlap: Double
        var sampleRate: Double
    }

    static func clampedWindow(_ seconds: Double, constraint: SNTimeDurationConstraint) -> Double {
        var w = seconds.isFinite && seconds > 0 ? seconds : 1.5
        switch constraint {
        case .durationRange(let r):
            let lo = r.start.seconds, hi = (r.start + r.duration).seconds
            if lo.isFinite, hi.isFinite, lo <= hi { w = min(max(w, lo), hi) }
        case .enumeratedDurations(let durations):
            let allowed = durations.map(\.seconds).filter(\.isFinite)
            if let best = allowed.min(by: { abs($0 - w) < abs($1 - w) }) { w = best }
        @unknown default:
            break
        }
        return w
    }

    /// Decodes [from, to] and classifies it; returns windows starting before `keepBefore` with watched-label scores
    /// at or above the threshold (windows with none are dropped). Blocking: run on `DecodeExecutor`.
    private static func classify(_ c: ChunkConfig, asset: AVURLAsset, tracks: [AVAssetTrack], from: Double, to: Double,
                                 keepBefore: Double, progress: @escaping (Double) -> Void) throws -> [Window] {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw SoundEventError.cannotRead(c.url, error.localizedDescription) }
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: c.sampleRate,
            AVNumberOfChannelsKey: 1,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw SoundEventError.cannotRead(c.url, "output not supported") }
        reader.add(output)
        let ts: CMTimeScale = 1_000_000
        reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: ts),
                                       duration: CMTime(seconds: max(0, to - from), preferredTimescale: ts))
        guard reader.startReading() else {
            throw SoundEventError.cannotRead(c.url, reader.error?.localizedDescription ?? "startReading failed")
        }
        defer { if reader.status == .reading { reader.cancelReading() } }

        let stream = try Stream(c, progress: progress)
        var base: Double?
        var scratch: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); throw CancellationError() }
            if base == nil {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                base = pts.isNumeric ? pts.seconds : from
            }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            if scratch.count < count { scratch = [Float](repeating: 0, count: count) }
            let status = scratch.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: $0.baseAddress!)
            }
            if status != kCMBlockBufferNoErr {
                throw SoundEventError.cannotRead(c.url, "CMBlockBufferCopyDataBytes failed (\(status))")
            }
            try scratch.withUnsafeBufferPointer { try stream.feed(UnsafeBufferPointer(rebasing: $0[..<count])) }
        }
        if reader.status == .failed {
            throw SoundEventError.cannotRead(c.url, reader.error?.localizedDescription ?? "reader failed")
        }
        let offset = base ?? from
        return try stream.finish().compactMap { w in
            let shifted = Window(start: w.start + offset, end: w.end + offset, scores: w.scores)
            return shifted.start < keepBefore - 1e-6 ? shifted : nil
        }
    }

    // MARK: - Streaming

    /// Classifies mono PCM pushed in pieces (one chunk of `analyze(url:)`, or the shared ingest's single stream).
    /// Audio goes to the analyzer a few seconds at a time: one analyze call per 1024-frame AAC packet costs noticeably
    /// more. Window times are relative to the first sample. Not thread-safe; feed from one queue.
    final class Stream: @unchecked Sendable {
        private let sampleRate: Double
        private let format: AVAudioFormat
        private let analyzer: SNAudioStreamAnalyzer
        private let collector: WindowCollector
        private let progress: (Double) -> Void
        private var pending: AVAudioPCMBuffer?
        private var position: AVAudioFramePosition = 0

        fileprivate convenience init(_ c: ChunkConfig, progress: @escaping (Double) -> Void) throws {
            try self.init(labels: c.labels, minConfidence: c.minConfidence, window: c.window, overlap: c.overlap,
                          sampleRate: c.sampleRate, progress: progress)
        }

        init(labels: Set<String>, minConfidence: Double, window: Double, overlap: Double, sampleRate: Double,
             progress: @escaping (Double) -> Void) throws {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
                throw SoundEventError.analysisFailed("unsupported sample rate \(sampleRate)")
            }
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = CMTime(seconds: window, preferredTimescale: CMTimeScale(sampleRate.rounded()))
            request.overlapFactor = overlap
            collector = WindowCollector(labels: labels, minConfidence: minConfidence)
            analyzer = SNAudioStreamAnalyzer(format: format)
            try analyzer.add(request, withObserver: collector)
            self.sampleRate = sampleRate
            self.format = format
            self.progress = progress
        }

        func feed(_ samples: UnsafeBufferPointer<Float>) throws {
            var offset = 0
            while offset < samples.count {
                if pending == nil { pending = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate * 4)) }
                guard let buffer = pending, let dst = buffer.floatChannelData?[0] else {
                    throw SoundEventError.analysisFailed("cannot allocate audio buffer")
                }
                let take = min(samples.count - offset, Int(buffer.frameCapacity - buffer.frameLength))
                (dst + Int(buffer.frameLength)).update(from: samples.baseAddress! + offset, count: take)
                buffer.frameLength += AVAudioFrameCount(take)
                offset += take
                if buffer.frameLength == buffer.frameCapacity { flush() }
            }
        }

        /// Ends the stream; returns the windows with a watched label at or above the threshold.
        func finish() throws -> [Window] {
            flush()
            analyzer.completeAnalysis()
            if let error = collector.error { throw SoundEventError.analysisFailed(error) }
            return collector.windows
        }

        private func flush() {
            guard let buffer = pending, buffer.frameLength > 0 else { return }
            analyzer.analyze(buffer, atAudioFramePosition: position)
            position += AVAudioFramePosition(buffer.frameLength)
            pending = nil
            progress(Double(position) / sampleRate)
        }
    }

    /// A stream for the shared ingest: the whole file in one pass (no chunks), with this analyzer's settings.
    /// Nil when there is nothing to watch for. Throws for labels the classifier doesn't know.
    func makeStream(sampleRate: Double, progress: @escaping (Double) -> Void) throws -> Stream? {
        guard !labels.isEmpty else { return nil }
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        let unknown = labels.subtracting(request.knownClassifications)
        if !unknown.isEmpty { throw SoundEventError.unknownLabels(unknown.sorted()) }
        return try Stream(labels: labels, minConfidence: minConfidence, window: streamWindow(request),
                          overlap: min(max(overlap, 0), 0.95), sampleRate: sampleRate, progress: progress)
    }

    /// The window `analyze(url:)` uses (clamped to the classifier's supported durations).
    func streamWindow(_ request: SNClassifySoundRequest) -> Double {
        Self.clampedWindow(windowDuration, constraint: request.windowDurationConstraint)
    }

    /// Events from a single stream's windows, shifted to source time by the stream's first sample time `base`.
    /// Media shorter than one window has none, as in `analyze(url:)`.
    func events(from windows: [Window], base: Double, duration: Double) throws -> SoundEvents {
        let window = streamWindow(try SNClassifySoundRequest(classifierIdentifier: .version1))
        guard duration >= window else { return SoundEvents(events: []) }
        let shifted = windows.map { Window(start: $0.start + base, end: $0.end + base, scores: $0.scores) }
        return SoundEvents(events: Self.merge(shifted, minConfidence: minConfidence, maxGap: maxGap))
    }
}

/// Receives classifier results (on SoundAnalysis' own threads) and keeps windows with a watched label above threshold.
private final class WindowCollector: NSObject, SNResultsObserving, Sendable {
    private struct State {
        var windows: [SoundEventAnalyzer.Window] = []
        var error: String?
    }

    private let labels: [String]
    private let minConfidence: Double
    private let state = Mutex(State())

    init(labels: Set<String>, minConfidence: Double) {
        self.labels = labels.sorted()
        self.minConfidence = minConfidence
    }

    var windows: [SoundEventAnalyzer.Window] { state.withLock { $0.windows } }
    var error: String? { state.withLock { $0.error } }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        var scores: [String: Double] = [:]
        for label in labels {
            if let c = result.classification(forIdentifier: label), c.confidence >= minConfidence { scores[label] = c.confidence }
        }
        guard !scores.isEmpty else { return }
        let start = result.timeRange.start.seconds
        let end = (result.timeRange.start + result.timeRange.duration).seconds
        state.withLock { $0.windows.append(.init(start: start, end: end, scores: scores)) }
    }

    func request(_ request: SNRequest, didFailWithError error: any Error) {
        state.withLock { $0.error = error.localizedDescription }
    }
}
