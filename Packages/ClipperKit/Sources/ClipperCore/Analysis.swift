import Foundation

// Analysis artifacts live in Core so Automation can consume them without importing the analyzers.
// Times are in seconds of *source* media: analysis is per asset, independent of any timeline.

public enum AnalysisKind: String, Sendable, CaseIterable, Codable {
    case speech, transcript, loudness, faces, beats, events, visual, color, keywords
}

public struct TranscriptWord: Codable, Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double
    public var confidence: Double?
    public var isFiller: Bool
    public init(text: String, start: Double, end: Double, confidence: Double? = nil, isFiller: Bool = false) {
        self.text = text; self.start = start; self.end = end; self.confidence = confidence; self.isFiller = isFiller
    }
}

public struct Transcript: Codable, Sendable, Equatable {
    public var locale: String
    public var engine: String
    public var words: [TranscriptWord]
    public init(locale: String, engine: String, words: [TranscriptWord]) {
        self.locale = locale; self.engine = engine; self.words = words
    }
    public var text: String { words.map(\.text).joined(separator: " ") }

    /// Sentences as ranges of `words`: one ends after a word that `endsSentence`, or where the next non-filler word
    /// starts 0.8 s or more after it. Everything that numbers sentences uses this split, so a sentence index
    /// (`TranscriptBrief.hookSentence`) means the same words everywhere.
    public static func sentences(_ words: [TranscriptWord]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start = 0
        for i in words.indices {
            let next = words[(i + 1)...].first { !$0.isFiller }
            let gap = next.map { $0.start - words[i].end } ?? 0
            let following = i + 1 < words.count ? words[i + 1].text : nil
            if endsSentence(words[i].text, next: following) || gap >= 0.8 {
                out.append(start..<(i + 1))
                start = i + 1
            }
        }
        if start < words.count { out.append(start..<words.count) }
        return out
    }

    /// Titles and other abbreviations a transcriber writes with a period mid-sentence.
    static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "mt", "vs", "e.g", "i.e", "approx", "dept", "inc", "ltd",
    ]

    /// Whether `text` ends a sentence: it ends in ".", "?" or "!", and the period is not an abbreviation's ("Dr.",
    /// "e.g."), an initial's ("J.") or one the next word carries on from in lowercase ("wait... what").
    public static func endsSentence(_ text: String, next: String? = nil) -> Bool {
        guard let last = text.last, ".?!".contains(last) else { return false }
        guard last == "." else { return true }
        let bare = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,;:\"'“”‘’()[]"))
        if abbreviations.contains(bare) || (bare.count == 1 && bare.first!.isLetter) { return false }
        if let first = next?.first(where: \.isLetter), first.isLowercase { return false }
        return true
    }
}

/// A uniformly sampled scalar series (e.g. RMS in dBFS every 10 ms).
public struct Envelope: Codable, Sendable, Equatable {
    public var hop: Double
    public var values: [Float]
    public init(hop: Double, values: [Float]) { self.hop = hop; self.values = values }

    public func value(at t: Double) -> Float {
        guard !values.isEmpty else { return -120 }
        return values[min(max(Int(t / hop), 0), values.count - 1)]
    }
    public var duration: Double { Double(values.count) * hop }
}

/// Where speech (voice) is present, plus the loudness envelope used to refine cut points.
public struct SpeechActivity: Codable, Sendable, Equatable {
    public struct Span: Codable, Sendable, Equatable {
        public var start: Double, end: Double
        public init(start: Double, end: Double) { self.start = start; self.end = end }
        public var duration: Double { end - start }
    }
    public var spans: [Span]
    public var rms: Envelope
    public var noiseFloor: Float
    public var threshold: Float
    public init(spans: [Span], rms: Envelope, noiseFloor: Float, threshold: Float) {
        self.spans = spans; self.rms = rms; self.noiseFloor = noiseFloor; self.threshold = threshold
    }
}

public struct BeatGrid: Codable, Sendable, Equatable {
    public var bpm: Double
    public var beats: [Double]
    public var downbeats: [Double]
    public init(bpm: Double, beats: [Double], downbeats: [Double] = []) { self.bpm = bpm; self.beats = beats; self.downbeats = downbeats }

    /// Fixes a double/half-tempo detection when the intended tempo is known (e.g. the BPM asked of a music generator):
    /// at ~2× the hint keeps every other beat (the phase containing the first downbeat); at ~½× inserts midpoints.
    /// Downbeats are re-derived every 4 beats. Returns self when no octave error is apparent.
    public func resolvingOctave(toward hint: Double) -> BeatGrid {
        guard hint > 0, bpm > 0, beats.count >= 4 else { return self }
        let ratio = bpm / hint
        var newBeats: [Double]
        if abs(ratio - 2) < 0.15 {
            let firstDown = downbeats.first ?? beats[0]
            let phase = (beats.firstIndex { abs($0 - firstDown) < 1e-6 } ?? 0) % 2
            newBeats = stride(from: phase, to: beats.count, by: 2).map { beats[$0] }
        } else if abs(ratio - 0.5) < 0.08 {
            newBeats = []
            for (a, b) in zip(beats, beats.dropFirst()) { newBeats += [a, (a + b) / 2] }
            newBeats.append(beats.last!)
        } else {
            return self
        }
        let downs = stride(from: 0, to: newBeats.count, by: 4).map { newBeats[$0] }
        return BeatGrid(bpm: bpm / (ratio > 1 ? 2 : 0.5), beats: newBeats, downbeats: downs)
    }

    public func nearestBeat(to t: Double) -> Double? {
        guard !beats.isEmpty else { return nil }
        var lo = 0, hi = beats.count - 1
        while lo < hi { let m = (lo + hi) / 2; if beats[m] < t { lo = m + 1 } else { hi = m } }
        let c = beats[lo]
        if lo > 0, abs(beats[lo - 1] - t) < abs(c - t) { return beats[lo - 1] }
        return c
    }
}

public struct LoudnessInfo: Codable, Sendable, Equatable {
    public var integrated: Double
    public var truePeak: Double
    public var range: Double
    public init(integrated: Double, truePeak: Double, range: Double) { self.integrated = integrated; self.truePeak = truePeak; self.range = range }
}

public struct FaceSample: Codable, Sendable, Equatable {
    public var time: Double
    /// Largest face, normalized to the *display-oriented* frame (rotation applied), origin top-left.
    public var rect: NormRect
    public var confidence: Double
    public init(time: Double, rect: NormRect, confidence: Double) { self.time = time; self.rect = rect; self.confidence = confidence }
}

public struct FaceTrack: Codable, Sendable, Equatable {
    public var samples: [FaceSample]
    public init(samples: [FaceSample]) { self.samples = samples }
}

/// A detected sound event (Apple SoundAnalysis classifier), e.g. laughter, applause, cheering.
public struct SoundEvent: Codable, Sendable, Equatable {
    public var label: String
    public var start: Double
    public var end: Double
    public var confidence: Double
    public init(label: String, start: Double, end: Double, confidence: Double) {
        self.label = label; self.start = start; self.end = end; self.confidence = confidence
    }
}

public struct SoundEvents: Codable, Sendable, Equatable {
    public var events: [SoundEvent]
    public init(events: [SoundEvent]) { self.events = events }
}

/// Coarse visual activity, sampled about once per second from keyframes.
public struct VisualSample: Codable, Sendable, Equatable {
    public var time: Double
    /// Difference to the previous sample, 0 (identical) … 1 (completely different).
    public var change: Double
    /// Most salient region (display-oriented, normalized, origin top-left), if any.
    public var salient: NormRect?
    /// Detail in the sampled frame (longest side 256 px), 0…1: v / (v + 500), where v is the variance of the 3×3
    /// Laplacian of its 8-bit luma. The fixed reference makes values comparable across clips sampled at that size:
    /// the testsrc2 fixture measures v ≈ 830 (0.62), blurred by σ = 4 px at 1080p ≈ 320 (0.39), by σ = 12 px ≈ 36
    /// (0.07). Nil in artifacts that predate it.
    public var sharpness: Double?
    /// Mean Rec. 709 luma of the display-referred frame, 0…1.
    public var luma: Double?
    public init(time: Double, change: Double, salient: NormRect?, sharpness: Double? = nil, luma: Double? = nil) {
        self.time = time; self.change = change; self.salient = salient; self.sharpness = sharpness; self.luma = luma
    }
}

public struct VisualActivity: Codable, Sendable, Equatable {
    public var samples: [VisualSample]
    /// Times of hard cuts / scene changes.
    public var sceneCuts: [Double]
    public init(samples: [VisualSample], sceneCuts: [Double]) { self.samples = samples; self.sceneCuts = sceneCuts }
}

/// Exposure and colour balance of a clip: medians over the frames `.visual` samples, display-referred (Rec. 709
/// R′G′B′ as shown), all 0…1.
public struct ColorStats: Codable, Sendable, Equatable {
    /// Mean luma.
    public var luma: Double
    /// 1st and 99th percentile luma: the frame's black and white points.
    public var p01: Double
    public var p99: Double
    /// Mean chroma, max(R′, G′, B′) − min(R′, G′, B′).
    public var saturation: Double
    /// Mean of each channel (grey world: equal means read as a neutral white balance).
    public var r: Double
    public var g: Double
    public var b: Double
    public init(luma: Double, p01: Double, p99: Double, saturation: Double, r: Double, g: Double, b: Double) {
        self.luma = luma; self.p01 = p01; self.p99 = p99; self.saturation = saturation; self.r = r; self.g = g; self.b = b
    }
}

/// Words worth calling out, from on-device part-of-speech and entity tagging. Indices into `Transcript.words`.
public struct KeywordTags: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case number, person, place, organization, noun, emphasis }
    public struct Tag: Codable, Sendable, Equatable {
        public var word: Int
        public var kind: Kind
        /// Lowercased dictionary form ("videos" → "video").
        public var lemma: String
        public var emoji: String?
        public init(word: Int, kind: Kind, lemma: String, emoji: String? = nil) {
            self.word = word; self.kind = kind; self.lemma = lemma; self.emoji = emoji
        }
    }
    public var tags: [Tag]
    public init(tags: [Tag]) { self.tags = tags }
}

/// What a local LLM said about a whole transcript. Sentence indices refer to `Transcript.sentences(_:)`.
public struct TranscriptBrief: Codable, Sendable, Equatable {
    public struct Chapter: Codable, Sendable, Equatable {
        /// Source seconds.
        public var start: Double
        public var title: String
        public init(start: Double, title: String) { self.start = start; self.title = title }
    }
    public var model: String
    /// At most 60 characters, no emoji, no quotes.
    public var title: String?
    public var hookSentence: Int?
    /// One 0…1 score per sentence, in order; empty when unknown.
    public var sentenceImportance: [Double]
    public var chapters: [Chapter]
    /// One to three sentences for a video description.
    public var description: String?
    /// Lowercase, without "#", at most 8.
    public var hashtags: [String]
    public init(model: String, title: String? = nil, hookSentence: Int? = nil, sentenceImportance: [Double] = [],
                chapters: [Chapter] = [], description: String? = nil, hashtags: [String] = []) {
        self.model = model; self.title = title; self.hookSentence = hookSentence
        self.sentenceImportance = sentenceImportance; self.chapters = chapters; self.description = description
        self.hashtags = hashtags
    }
}

/// Everything known about one asset. Fields are nil until that analyzer has run.
public struct AssetAnalysis: Codable, Sendable, Equatable {
    public var transcript: Transcript?
    public var speech: SpeechActivity?
    public var loudness: LoudnessInfo?
    public var faces: FaceTrack?
    public var beats: BeatGrid?
    public var events: SoundEvents?
    public var visual: VisualActivity?
    public var color: ColorStats?
    public var keywords: KeywordTags?
    /// Only when a local LLM ran (`TranscriptBriefer`); the analysis pipeline never sets it.
    public var brief: TranscriptBrief?
    public init(transcript: Transcript? = nil, speech: SpeechActivity? = nil, loudness: LoudnessInfo? = nil,
                faces: FaceTrack? = nil, beats: BeatGrid? = nil, events: SoundEvents? = nil, visual: VisualActivity? = nil,
                color: ColorStats? = nil, keywords: KeywordTags? = nil, brief: TranscriptBrief? = nil) {
        self.transcript = transcript; self.speech = speech; self.loudness = loudness; self.faces = faces; self.beats = beats
        self.events = events; self.visual = visual; self.color = color; self.keywords = keywords; self.brief = brief
    }
}

/// A candidate short cut from a long recording.
public struct Highlight: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(Int((start * 1000).rounded()))-\(Int((end * 1000).rounded()))" }
    /// Source range in seconds.
    public var start: Double
    public var end: Double
    /// 0…1, higher is better.
    public var score: Double
    /// Why it was picked (shown to the user).
    public var reason: String
    /// Suggested hook/title, if a ranker produced one.
    public var title: String?
    /// Transcript excerpt.
    public var text: String
    /// Named signal values that went into the score (for transparency and tuning).
    public var signals: [String: Double]

    public init(start: Double, end: Double, score: Double, reason: String, title: String? = nil, text: String, signals: [String: Double] = [:]) {
        self.start = start; self.end = end; self.score = score; self.reason = reason; self.title = title; self.text = text; self.signals = signals
    }
    public var duration: Double { end - start }
}
