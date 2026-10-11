import ClipperCore
import ClipperEngine
import CryptoKit
import Foundation

public enum AnalysisKind: String, Sendable, CaseIterable, Codable {
    case speech, transcript, loudness, faces, beats
}

public struct AnalysisOptions: Sendable {
    public var locale: Locale
    public var transcriber: any Transcriber
    public var faces: FaceAnalyzer

    public init(locale: Locale = Locale(identifier: "en-US"), transcriber: any Transcriber = AppleTranscriber(),
                faces: FaceAnalyzer = FaceAnalyzer()) {
        self.locale = locale; self.transcriber = transcriber; self.faces = faces
    }
}

public enum AnalysisPipelineError: Error, Sendable, CustomStringConvertible {
    /// Some analyzers failed. `partial` holds everything that did succeed (and was cached), so callers can still use it.
    case analyzersFailed([AnalysisKind: String], partial: AssetAnalysis)

    public var description: String {
        switch self {
        case .analyzersFailed(let errors, _):
            "Analysis failed: " + errors.sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.rawValue): \($0.value)" }.joined(separator: "; ")
        }
    }
}

/// Runs analyzers for assets and merges their artifacts into an `AssetAnalysis`, reusing cached results.
///
/// - Cache: results are stored per `(asset.key, analyzerID, version(of: kind))` as JSON (`ClipperJSON`, compact).
///   The transcript is cached *raw* (engine timings); boundary snapping against the speech envelope and filler marking
///   are cheap and re-applied on every call, so improving the snapper never needs a transcription re-run.
///   Analyzer IDs include whatever changes the output (transcriber engine + locale, face sampling rate).
///   Cache write failures are ignored (the result is still returned; it will simply be recomputed next time).
/// - Applicability: kinds that don't apply are skipped, not errors. No audio track → no speech/transcript/loudness;
///   `faces` needs a video or image; `beats` only runs for audio-only (music) assets.
///   Requesting `transcript` also computes (and returns) `speech`, which the snapper needs.
/// - Concurrency: up to `maxConcurrent` assets are analyzed at once (further calls wait for a slot, FIFO).
///   Within one asset the independent analyzers run in parallel (audio decode, ANE transcription, video decode).
/// - Errors/cancellation: an analyzer failure does not stop the others; successes are cached and the call throws
///   `AnalysisPipelineError.analyzersFailed` carrying the partial result. Cancelling the calling task cancels all
///   analyzers and throws `CancellationError`.
public actor AnalysisPipeline {
    public typealias Progress = @Sendable (AnalysisKind, Double) -> Void

    private let cache: (any AnalysisCache)?
    private let options: AnalysisOptions
    private let maxConcurrent: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(cache: (any AnalysisCache)?, options: AnalysisOptions = .init(), maxConcurrent: Int = 2) {
        self.cache = cache
        self.options = options
        self.maxConcurrent = max(1, maxConcurrent)
    }

    /// Bump a kind's version whenever its algorithm or output format changes; that invalidates only its cache entries.
    public static func version(of kind: AnalysisKind) -> Int {
        switch kind {
        case .speech: 1
        case .transcript: 1
        case .loudness: 1
        case .faces: 1
        case .beats: 1
        }
    }

    /// The subset of `kinds` that applies to media described by `info`.
    public static func applicableKinds(_ kinds: Set<AnalysisKind>, for info: MediaInfo) -> Set<AnalysisKind> {
        kinds.filter { kind in
            switch kind {
            case .speech, .transcript, .loudness: info.hasAudio
            case .faces: info.hasVideo
            case .beats: info.kind == .audio && info.hasAudio
            }
        }
    }

    /// Cache identifier of the analyzer producing `kind` under `options`.
    public static func analyzerID(_ kind: AnalysisKind, options: AnalysisOptions) -> String {
        switch kind {
        case .speech: "speech.rms16k"
        case .transcript: "transcript.\(options.transcriber.id).\(options.locale.identifier(.bcp47))"
        case .loudness: "loudness.r128"
        case .faces: "faces.vision.\(String(format: "%g", options.faces.samplesPerSecond))fps"
        case .beats: "beats"
        }
    }

    /// Runs the requested analyzers for an asset, reusing cached results (keyed by asset.key + analyzer id + version),
    /// returning a merged AssetAnalysis. Dependencies: transcript needs speech (for BoundarySnapper), so speech is
    /// computed alongside it and the snap is applied once both are ready.
    public func analyze(_ asset: MediaAsset, kinds: Set<AnalysisKind>,
                        progress: Progress? = nil) async throws -> AssetAnalysis {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await Self.run(asset, kinds: kinds, cache: cache, options: options, progress: progress)
    }

    // MARK: - Slots

    private func acquire() async {
        if running < maxConcurrent { running += 1; return }
        await withCheckedContinuation { waiters.append($0) }   // the releasing call hands its slot over
    }

    private func release() {
        if waiters.isEmpty { running -= 1 } else { waiters.removeFirst().resume() }
    }

    // MARK: - Execution

    private enum Output: Sendable {
        case speech(SpeechActivity)
        case transcript(Transcript)
        case loudness(LoudnessInfo)
        case faces(FaceTrack)
        case beats(BeatGrid)
    }

    private static func run(_ asset: MediaAsset, kinds: Set<AnalysisKind>, cache: (any AnalysisCache)?,
                            options: AnalysisOptions, progress: Progress?) async throws -> AssetAnalysis {
        var plan = applicableKinds(kinds, for: asset.info)
        if plan.contains(.transcript) { plan.insert(.speech) }
        guard !plan.isEmpty else { return AssetAnalysis() }
        let url = asset.renderURL
        let info = asset.info
        let key = asset.key

        let results = await withTaskGroup(of: (AnalysisKind, Result<Output, Error>).self,
                                          returning: [(AnalysisKind, Result<Output, Error>)].self) { group in
            for kind in plan {
                group.addTask(executorPreference: DecodeExecutor.shared) {
                    (kind, await compute(kind, url: url, info: info, key: key, cache: cache, options: options,
                                         progress: progress))
                }
            }
            var all: [(AnalysisKind, Result<Output, Error>)] = []
            for await r in group { all.append(r) }
            return all
        }
        try Task.checkCancellation()

        var analysis = AssetAnalysis()
        var rawTranscript: Transcript?
        var failures: [AnalysisKind: String] = [:]
        for (kind, result) in results {
            switch result {
            case .success(.speech(let s)): analysis.speech = s
            case .success(.transcript(let t)): rawTranscript = t
            case .success(.loudness(let l)): analysis.loudness = l
            case .success(.faces(let f)): analysis.faces = f
            case .success(.beats(let b)): analysis.beats = b
            case .failure(let error):
                if error is CancellationError { throw error }
                failures[kind] = String(describing: error)
            }
        }
        if var t = rawTranscript {
            if let speech = analysis.speech { t.words = BoundarySnapper.snap(t.words, activity: speech) }
            t.words = Fillers.markFillers(t.words)
            analysis.transcript = t
        }
        if !failures.isEmpty { throw AnalysisPipelineError.analyzersFailed(failures, partial: analysis) }
        return analysis
    }

    private static func compute(_ kind: AnalysisKind, url: URL, info: MediaInfo, key: AssetKey,
                                cache: (any AnalysisCache)?, options: AnalysisOptions,
                                progress: Progress?) async -> Result<Output, Error> {
        let id = analyzerID(kind, options: options)
        do {
            switch kind {
            case .speech:
                let s: SpeechActivity = try await cached(kind, id, key, cache, progress) {
                    try await speechActivity(url: url, duration: info.duration.seconds)
                }
                return .success(.speech(s))
            case .transcript:
                let t: Transcript = try await cached(kind, id, key, cache, progress) {
                    try await options.transcriber.transcribe(url: url, locale: options.locale, range: nil)
                }
                return .success(.transcript(t))
            case .loudness:
                let l: LoudnessInfo = try await cached(kind, id, key, cache, progress) {
                    try await AudioFileLoudness.measure(url: url)
                }
                return .success(.loudness(l))
            case .faces:
                let report: (@Sendable (Double) -> Void)? = progress.map { p in { @Sendable f in p(.faces, f) } }
                let f: FaceTrack = try await cached(kind, id, key, cache, progress) {
                    try await options.faces.analyze(url: url, info: info, range: nil, progress: report)
                }
                return .success(.faces(f))
            case .beats:
                let b: BeatGrid = try await cached(kind, id, key, cache, progress) {
                    try await MusicAnalyzer.analyze(url: url).beats
                }
                return .success(.beats(b))
            }
        } catch {
            return .failure(error)
        }
    }

    /// Loads `kind` from the cache or computes and stores it.
    private static func cached<T: Codable & Sendable>(
        _ kind: AnalysisKind, _ analyzer: String, _ key: AssetKey, _ cache: (any AnalysisCache)?, _ progress: Progress?,
        compute: @Sendable () async throws -> T
    ) async throws -> T {
        let version = version(of: kind)
        if let cache, let data = await cache.load(key: key, analyzer: analyzer, version: version),
           let value = try? CacheCodec.decoder.decode(T.self, from: data) {
            progress?(kind, 1)
            return value
        }
        try Task.checkCancellation()
        progress?(kind, 0)
        let value = try await compute()
        try Task.checkCancellation()
        if let cache, let data = try? CacheCodec.encoder.encode(value) {
            try? await cache.store(data, key: key, analyzer: analyzer, version: version)
        }
        progress?(kind, 1)
        return value
    }

    // MARK: - Speech activity

    /// Seconds of audio decoded per read when building the envelope of long files (bounded memory: 5 min at 16 kHz
    /// is ~19 MB of Float32). A multiple of the 10 ms hop so chunk envelopes concatenate exactly.
    static let speechChunk = 300.0

    /// RMS envelope (16 kHz mono, 10 ms hop) → `SpeechActivityDetector`.
    static func speechActivity(url: URL, duration: Double) async throws -> SpeechActivity {
        let sr = 16_000.0
        let hop = 0.01
        var values: [Float] = []
        if !(duration > speechChunk * 1.5) {
            let samples = try await AudioReader.readMono(url: url, sampleRate: sr)
            values = Envelope.rms(samples: samples, sampleRate: sr, hop: hop).values
        } else {
            let perChunk = Int(speechChunk * sr)
            var start = 0.0
            while start < duration {
                try Task.checkCancellation()
                let end = min(start + speechChunk, duration)
                var samples = try await AudioReader.readMono(url: url, sampleRate: sr, range: start...end)
                if end < duration {
                    // Pin every chunk to exactly `speechChunk` seconds so envelope frames stay on the source timeline.
                    if samples.count > perChunk { samples.removeLast(samples.count - perChunk) }
                    if samples.count < perChunk { samples += repeatElement(0, count: perChunk - samples.count) }
                }
                values += Envelope.rms(samples: samples, sampleRate: sr, hop: hop).values
                start = end
            }
        }
        return SpeechActivityDetector().detect(Envelope(hop: hop, values: values))
    }
}

/// JSON for cached artifacts: `ClipperJSON` settings, compact (envelopes are large), and tolerant of the ±∞ that
/// loudness reports for silence.
enum CacheCodec {
    static var encoder: JSONEncoder {
        let e = ClipperJSON.encoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }

    static var decoder: JSONDecoder {
        let d = ClipperJSON.decoder()
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return d
    }
}

/// `AnalysisCache` in a plain directory: `<directory>/<assetKey>/<analyzer>@<version>.json`. Used by the CLI and tests.
public struct DirectoryAnalysisCache: AnalysisCache {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public func fileURL(key: AssetKey, analyzer: String, version: Int) -> URL {
        // Path components must never resolve outside `directory`: separators are replaced, and anything that is
        // empty, "." / "..", or contains NUL is replaced by its SHA-256 (keys are normally hex content hashes anyway).
        let safe = { (s: String) -> String in
            let swept = String(s.map { $0 == "/" || $0 == ":" || $0 == "\\" ? "_" : $0 })
            if swept.isEmpty || swept == "." || swept == ".." || swept.contains("\0") || swept.hasPrefix(".") {
                return SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
            }
            return swept
        }
        return directory.appendingPathComponent(safe(key.rawValue), isDirectory: true)
            .appendingPathComponent("\(safe(analyzer))@\(version).json")
    }

    public func load(key: AssetKey, analyzer: String, version: Int) async -> Data? {
        try? Data(contentsOf: fileURL(key: key, analyzer: analyzer, version: version))
    }

    public func store(_ data: Data, key: AssetKey, analyzer: String, version: Int) async throws {
        let url = fileURL(key: key, analyzer: analyzer, version: version)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
