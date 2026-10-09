import Foundation

// Analysis artifacts live in Core so Automation can consume them without importing the analyzers.
// Times are in seconds of *source* media: analysis is per asset, independent of any timeline.

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

/// Everything known about one asset. Fields are nil until that analyzer has run.
public struct AssetAnalysis: Codable, Sendable, Equatable {
    public var transcript: Transcript?
    public var speech: SpeechActivity?
    public var loudness: LoudnessInfo?
    public var faces: FaceTrack?
    public var beats: BeatGrid?
    public init(transcript: Transcript? = nil, speech: SpeechActivity? = nil, loudness: LoudnessInfo? = nil,
                faces: FaceTrack? = nil, beats: BeatGrid? = nil) {
        self.transcript = transcript; self.speech = speech; self.loudness = loudness; self.faces = faces; self.beats = beats
    }
}
