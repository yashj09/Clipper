import ClipperCore
import CryptoKit
import Foundation

/// Generates instrumental music locally through the Python worker (ACE-Step 1.5, MIT code and weights), then analyzes
/// it like any other track so the music picker and BeatSnap can use it.
public struct MusicGenerator: Sendable {
    public let worker: PythonWorker
    /// Longest the worker may go without reporting progress. The worker reports every second or so while downloading
    /// weights (6.3 GB on first use) and while generating, so this only trips on a hung worker; model loading is the
    /// longest silent stretch.
    public var timeout: Duration

    public init(worker: PythonWorker, timeout: Duration = .seconds(600)) {
        self.worker = worker; self.timeout = timeout
    }

    /// A generator on the default worker project with the `music` extra enabled, or nil if uv or the project is missing.
    public static func makeDefault(environment: [String: String] = [:]) -> MusicGenerator? {
        guard PythonWorker.isUVAvailable(), let dir = PythonWorker.defaultProjectDirectory() else { return nil }
        return MusicGenerator(worker: PythonWorker(projectDirectory: dir, extras: ["music"], environment: environment))
    }

    /// Whether the worker has the music extra installed (starts the worker if needed).
    public func isAvailable() async -> Bool {
        (try? await worker.call("capabilities", timeout: .seconds(120)))?["music_generation"]?.boolValue ?? false
    }

    /// Generates `duration` seconds of instrumental music from `prompt` into `outputDirectory` (WAV, 48 kHz stereo).
    /// - Parameters:
    ///   - bpm: tempo hint for the model; the returned track's `bpm` is what the beat tracker measured.
    ///   - moods: canonical moods for the picker; inferred from the prompt's words when nil.
    ///   - progress: 0…1 with a short status message (loading, generating, decoding).
    /// - Returns: the analyzed track, licensed `.generated(model:)`.
    public func generate(prompt: String, duration: Double, bpm: Double? = nil, seed: Int = 0, outputDirectory: URL,
                         moods: [String]? = nil,
                         progress: (@Sendable (WorkerProgress) -> Void)? = nil) async throws -> MusicTrack {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let id = Self.trackID(prompt: prompt, duration: duration, bpm: bpm, seed: seed)
        let outURL = outputDirectory.appending(path: "\(id).wav")

        var params: [String: JSONValue] = [
            "prompt": .string(prompt), "duration_s": .number(duration), "seed": .number(Double(seed)),
            "out_path": .string(outURL.path), "instrumental": true,
        ]
        if let bpm { params["bpm"] = .number(bpm.rounded()) }
        let result = try await worker.call("generate_music", params: .object(params), timeout: timeout, progress: progress)
        guard let path = result["path"]?.stringValue else { throw WorkerError.badResponse("generate_music returned no path") }
        let model = result["model"]?.stringValue ?? "ACE-Step 1.5"

        let url = URL(fileURLWithPath: path)
        var analysis = try await MusicAnalyzer.analyze(url: url)
        // Hi-hat-heavy genres often read as double tempo; we know what tempo was asked for.
        if let bpm { analysis.beats = analysis.beats.resolvingOctave(toward: bpm) }
        let measuredBPM = analysis.beats.bpm > 0 ? analysis.beats.bpm : bpm
        return MusicTrack(
            id: id, title: Self.title(for: prompt), artist: model, url: url, duration: analysis.duration,
            license: .generated(model: model), moods: moods ?? MusicMoods.infer(from: prompt),
            genres: MusicMoods.genres(in: prompt), bpm: measuredBPM, energy: analysis.energy,
            beats: analysis.beats.beats.isEmpty ? nil : analysis.beats)
    }

    /// Stable id/file name for a request: same prompt and settings → same file.
    static func trackID(prompt: String, duration: Double, bpm: Double?, seed: Int) -> String {
        let key = "\(prompt.lowercased())|\(duration)|\(bpm.map { String($0.rounded()) } ?? "-")|\(seed)"
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "generated-\(hash)"
    }

    static func title(for prompt: String) -> String {
        let firstClause = prompt.split(separator: ",").first.map(String.init) ?? prompt
        var title = firstClause.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.count > 48 { title = String(title.prefix(47)).trimmingCharacters(in: .whitespaces) + "…" }
        guard let first = title.first else { return "Generated track" }
        return first.uppercased() + title.dropFirst()
    }
}

/// Prompt words → Clipper's canonical moods (`ClipperAutomation.Mood.canonical`; duplicated here because
/// ClipperAnalysis doesn't depend on Automation) and a few common genre tags.
public enum MusicMoods {
    static let keywords: [String: [String]] = [
        "chill": ["chill"], "chillhop": ["chill"], "lofi": ["chill"], "lo-fi": ["chill"], "relaxed": ["chill"],
        "relaxing": ["chill"], "calm": ["chill"], "mellow": ["chill"], "ambient": ["chill", "cinematic"],
        "smooth": ["chill"], "dreamy": ["chill"], "warm": ["chill"],
        "upbeat": ["upbeat"], "bouncy": ["upbeat", "happy"], "groovy": ["upbeat"], "funky": ["upbeat"], "funk": ["upbeat"],
        "happy": ["happy"], "cheerful": ["happy"], "joyful": ["happy"], "bright": ["happy"], "sunny": ["happy"],
        "inspiring": ["inspiring"], "inspirational": ["inspiring"], "uplifting": ["inspiring", "happy"],
        "hopeful": ["inspiring"], "motivational": ["inspiring", "energetic"], "triumphant": ["inspiring", "cinematic"],
        "energetic": ["energetic"], "driving": ["energetic"], "fast": ["energetic"], "edm": ["energetic"],
        "dance": ["energetic", "upbeat"], "hype": ["energetic"], "powerful": ["energetic", "intense"],
        "intense": ["intense"], "aggressive": ["intense"], "heavy": ["intense"], "action": ["intense", "energetic"],
        "metal": ["intense"], "tense": ["intense", "mysterious"],
        "cinematic": ["cinematic"], "epic": ["cinematic", "inspiring"], "orchestral": ["cinematic"],
        "trailer": ["cinematic", "intense"], "score": ["cinematic"],
        "dark": ["dark"], "sad": ["dark"], "melancholy": ["dark"], "melancholic": ["dark"], "somber": ["dark"],
        "ominous": ["dark", "mysterious"], "eerie": ["dark", "mysterious"], "gloomy": ["dark"],
        "funny": ["funny"], "quirky": ["funny"], "playful": ["funny", "happy"], "comedic": ["funny"], "silly": ["funny"],
        "mysterious": ["mysterious"], "mystery": ["mysterious"], "suspense": ["mysterious", "intense"],
        "suspenseful": ["mysterious", "intense"], "mystical": ["mysterious"],
    ]

    static let genreWords: [(match: [String], genre: String)] = [
        (["lo-fi", "lofi", "chillhop"], "lo-fi"), (["hip hop", "hip-hop", "hiphop", "boom bap"], "hip hop"),
        (["edm", "electronic", "synth"], "electronic"), (["house"], "house"), (["techno"], "techno"),
        (["trap"], "trap"), (["rock"], "rock"), (["metal"], "metal"), (["jazz"], "jazz"), (["funk"], "funk"),
        (["pop"], "pop"), (["ambient"], "ambient"), (["orchestral", "orchestra", "cinematic"], "orchestral"),
        (["piano"], "piano"), (["acoustic", "guitar"], "acoustic"), (["synthwave", "retrowave"], "synthwave"),
        (["classical"], "classical"), (["reggae"], "reggae"), (["country"], "country"), (["r&b", "rnb", "soul"], "r&b"),
    ]

    /// Canonical moods in the order their words first appear in the prompt.
    public static func infer(from prompt: String) -> [String] {
        var out: [String] = []
        for word in words(in: prompt) {
            for mood in keywords[word] ?? [] where !out.contains(mood) { out.append(mood) }
        }
        return out
    }

    public static func genres(in prompt: String) -> [String] {
        let text = " " + words(in: prompt).joined(separator: " ") + " "
        return genreWords.compactMap { entry in
            entry.match.contains { text.contains(" \($0) ") } ? entry.genre : nil
        }
    }

    private static func words(in prompt: String) -> [String] {
        prompt.lowercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "&") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
            .filter { !$0.isEmpty }
    }
}
