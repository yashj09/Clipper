import ClipperCore
import ClipperEngine
import CryptoKit
import Foundation

public struct AnalysisOptions: Sendable {
    public var locale: Locale
    public var transcriber: any Transcriber
    public var faces: FaceAnalyzer
    public var events: SoundEventAnalyzer
    public var visual: VisualActivityAnalyzer

    public init(locale: Locale = Locale(identifier: "en-US"), transcriber: any Transcriber = AppleTranscriber(),
                faces: FaceAnalyzer = FaceAnalyzer(), events: SoundEventAnalyzer = SoundEventAnalyzer(),
                visual: VisualActivityAnalyzer = VisualActivityAnalyzer()) {
        self.locale = locale; self.transcriber = transcriber; self.faces = faces
        self.events = events; self.visual = visual
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
/// - Applicability: kinds that don't apply are skipped, not errors. No audio track → no speech/transcript/loudness/
///   events; `faces` and `visual` need a video or image; `beats` only runs for audio-only (music) assets.
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
        case .transcript: 2   // 2: Apple transcripts are fed from the shared ingest (Resampler instead of AVAssetReader resampling)
        case .loudness: 1
        case .faces: 1
        case .beats: 1
        case .events: 1
        case .visual: 1
        }
    }

    /// The subset of `kinds` that applies to media described by `info`.
    public static func applicableKinds(_ kinds: Set<AnalysisKind>, for info: MediaInfo) -> Set<AnalysisKind> {
        kinds.filter { kind in
            switch kind {
            case .speech, .transcript, .loudness, .events: info.hasAudio
            case .faces, .visual: info.hasVideo
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
        case .events: "events.\(eventsSignature(options.events))"
        case .visual: "visual.\(visualSignature(options.visual))"
        }
    }

    /// Everything that changes `SoundEventAnalyzer` output: window, overlap, threshold, merge gap and the label set
    /// (hashed, since it can be long).
    static func eventsSignature(_ e: SoundEventAnalyzer) -> String {
        let labels = SHA256.hash(data: Data(e.labels.sorted().joined(separator: ",").utf8))
            .prefix(4).map { String(format: "%02x", $0) }.joined()
        return String(format: "sa1.w%g.o%g.c%g.g%g.", e.windowDuration, e.overlap, e.minConfidence, e.maxGap) + labels
    }

    /// Everything that changes `VisualActivityAnalyzer` output.
    static func visualSignature(_ v: VisualActivityAnalyzer) -> String {
        String(format: "%gs.t%g.px%g.cut%g-%g-%d", v.interval, v.tolerance, v.maximumSize, v.minCutChange, v.cutSigma,
               v.cutWindow) + (v.saliency ? ".sal" : "")
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
        case events(SoundEvents)
        case visual(VisualActivity)
    }

    private static func run(_ asset: MediaAsset, kinds: Set<AnalysisKind>, cache: (any AnalysisCache)?,
                            options: AnalysisOptions, progress: Progress?) async throws -> AssetAnalysis {
        var plan = applicableKinds(kinds, for: asset.info)
        if plan.contains(.transcript) { plan.insert(.speech) }
        guard !plan.isEmpty else { return AssetAnalysis() }
        let url = asset.renderURL
        let info = asset.info
        let key = asset.key

        // Cached kinds first; only the misses decode anything.
        var results: [(AnalysisKind, Result<Output, Error>)] = []
        var misses: Set<AnalysisKind> = []
        for kind in plan {
            if let hit = await loadCached(kind, analyzerID(kind, options: options), key, cache) {
                progress?(kind, 1)
                results.append((kind, .success(hit)))
            } else {
                misses.insert(kind)
            }
        }
        let shared = sharedAudioKinds(misses, options: options)

        let computed = await withTaskGroup(of: [(AnalysisKind, Result<Output, Error>)].self,
                                           returning: [(AnalysisKind, Result<Output, Error>)].self) { group in
            if !shared.isEmpty {
                group.addTask(executorPreference: DecodeExecutor.shared) {
                    await ingestAudio(shared, url: url, info: info, key: key, cache: cache, options: options, progress: progress)
                }
            }
            for kind in misses.subtracting(shared) {
                group.addTask(executorPreference: DecodeExecutor.shared) {
                    [(kind, await compute(kind, url: url, info: info, key: key, cache: cache, options: options,
                                          progress: progress))]
                }
            }
            var all: [(AnalysisKind, Result<Output, Error>)] = []
            for await r in group { all += r }
            return all
        }
        results += computed
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
            case .success(.events(let e)): analysis.events = e
            case .success(.visual(let v)): analysis.visual = v
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
                let s: SpeechActivity = try await computed(kind, id, key, cache, progress) {
                    try await speechActivity(url: url, duration: info.duration.seconds)
                }
                return .success(.speech(s))
            case .transcript:
                let t: Transcript = try await computed(kind, id, key, cache, progress) {
                    try await options.transcriber.transcribe(url: url, locale: options.locale, range: nil)
                }
                return .success(.transcript(t))
            case .loudness:
                let l: LoudnessInfo = try await computed(kind, id, key, cache, progress) {
                    try await AudioFileLoudness.measure(url: url)
                }
                return .success(.loudness(l))
            case .faces:
                let report: (@Sendable (Double) -> Void)? = progress.map { p in { @Sendable f in p(.faces, f) } }
                let f: FaceTrack = try await computed(kind, id, key, cache, progress) {
                    try await options.faces.analyze(url: url, info: info, range: nil, progress: report)
                }
                return .success(.faces(f))
            case .beats:
                let b: BeatGrid = try await computed(kind, id, key, cache, progress) {
                    try await MusicAnalyzer.analyze(url: url).beats
                }
                return .success(.beats(b))
            case .events:
                let report: (@Sendable (Double) -> Void)? = progress.map { p in { @Sendable f in p(.events, f) } }
                let e: SoundEvents = try await computed(kind, id, key, cache, progress) {
                    try await options.events.analyze(url: url, range: nil, progress: report)
                }
                return .success(.events(e))
            case .visual:
                let report: (@Sendable (Double) -> Void)? = progress.map { p in { @Sendable f in p(.visual, f) } }
                let v: VisualActivity = try await computed(kind, id, key, cache, progress) {
                    try await options.visual.analyze(url: url, info: info, range: nil, progress: report)
                }
                return .success(.visual(v))
            }
        } catch {
            return .failure(error)
        }
    }

    /// The cached artifact for `kind`, if there is a readable one at the current version.
    private static func loadCached(_ kind: AnalysisKind, _ analyzer: String, _ key: AssetKey,
                                   _ cache: (any AnalysisCache)?) async -> Output? {
        guard let cache, let data = await cache.load(key: key, analyzer: analyzer, version: version(of: kind)) else { return nil }
        let d = CacheCodec.decoder
        switch kind {
        case .speech: return (try? d.decode(SpeechActivity.self, from: data)).map(Output.speech)
        case .transcript: return (try? d.decode(Transcript.self, from: data)).map(Output.transcript)
        case .loudness: return (try? d.decode(LoudnessInfo.self, from: data)).map(Output.loudness)
        case .faces: return (try? d.decode(FaceTrack.self, from: data)).map(Output.faces)
        case .beats: return (try? d.decode(BeatGrid.self, from: data)).map(Output.beats)
        case .events: return (try? d.decode(SoundEvents.self, from: data)).map(Output.events)
        case .visual: return (try? d.decode(VisualActivity.self, from: data)).map(Output.visual)
        }
    }

    /// Computes `kind` (a cache miss) and stores it.
    private static func computed<T: Codable & Sendable>(
        _ kind: AnalysisKind, _ analyzer: String, _ key: AssetKey, _ cache: (any AnalysisCache)?, _ progress: Progress?,
        compute: @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        progress?(kind, 0)
        let value = try await compute()
        try Task.checkCancellation()
        await store(value, kind, analyzer, key, cache)
        progress?(kind, 1)
        return value
    }

    private static func store<T: Encodable>(_ value: T, _ kind: AnalysisKind, _ analyzer: String, _ key: AssetKey,
                                            _ cache: (any AnalysisCache)?) async {
        if let cache, let data = try? CacheCodec.encoder.encode(value) {
            try? await cache.store(data, key: key, analyzer: analyzer, version: version(of: kind))
        }
    }

    // MARK: - Shared audio ingest

    /// The missed kinds to compute from one shared audio decode (`AudioIngest`). Speech always goes through it, as
    /// does the transcript when the transcriber accepts PCM, so each has one algorithm whatever else is requested.
    /// Loudness and events join only when they share the decode with another kind; alone they keep their own
    /// readers (events then splits long media into chunks decoded in parallel, which is faster for that case).
    static func sharedAudioKinds(_ misses: Set<AnalysisKind>, options: AnalysisOptions) -> Set<AnalysisKind> {
        var shared = misses.intersection([.speech])
        if misses.contains(.transcript), options.transcriber is any PCMStreamTranscriber { shared.insert(.transcript) }
        let joiners = misses.intersection([.loudness, .events])
        if shared.count + joiners.count >= 2 { shared.formUnion(joiners) }
        return shared
    }

    private static func ingestAudio(_ kinds: Set<AnalysisKind>, url: URL, info: MediaInfo, key: AssetKey,
                                    cache: (any AnalysisCache)?, options: AnalysisOptions,
                                    progress: Progress?) async -> [(AnalysisKind, Result<Output, Error>)] {
        if Task.isCancelled { return kinds.map { ($0, .failure(CancellationError())) } }
        for kind in kinds { progress?(kind, 0) }
        var request = AudioIngest.Request()
        request.speech = kinds.contains(.speech)
        request.loudness = kinds.contains(.loudness)
        request.events = kinds.contains(.events) ? options.events : nil
        request.transcriber = kinds.contains(.transcript) ? options.transcriber as? any PCMStreamTranscriber : nil
        request.locale = options.locale
        let report: (@Sendable (Double) -> Void)? = progress.map { p in { @Sendable f in p(.events, f) } }
        let r = await AudioIngest.run(url: url, duration: info.duration.seconds, request: request, eventsProgress: report)

        var out: [(AnalysisKind, Result<Output, Error>)] = []
        func add<T: Codable & Sendable>(_ kind: AnalysisKind, _ result: Result<T, Error>?, _ wrap: (T) -> Output) async {
            guard let result else { return }
            switch result {
            case .success(let value):
                if !Task.isCancelled { await store(value, kind, analyzerID(kind, options: options), key, cache) }
                progress?(kind, 1)
                out.append((kind, .success(wrap(value))))
            case .failure(let error):
                out.append((kind, .failure(error)))
            }
        }
        await add(.speech, r.speech, Output.speech)
        await add(.loudness, r.loudness, Output.loudness)
        await add(.events, r.events, Output.events)
        await add(.transcript, r.transcript, Output.transcript)
        if Task.isCancelled { return kinds.map { ($0, .failure(CancellationError())) } }
        return out
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
