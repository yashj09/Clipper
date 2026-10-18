import Foundation

public enum ContentType: String, Codable, Sendable, CaseIterable {
    case talkingHead, gameplay, montage, vlog, custom
}

public enum SlotRole: String, Codable, Sendable {
    /// The main storyline; clips are placed back-to-back and drive the duration.
    case primary
    /// A secondary visual stacked with the primary (e.g. gameplay under a facecam).
    case secondary
    /// Cutaways placed over the primary.
    case broll
    case logo
    case background
}

/// How a slot is filled from the clips assigned to it.
public enum SlotFill: String, Codable, Sendable {
    /// Clips back-to-back (after cutting); the primary storyline.
    case sequence
    /// One clip, looped/trimmed to cover the whole timeline (e.g. background gameplay).
    case loop
    /// One clip, for the whole duration, not looped.
    case single
    /// Mirrors the primary slot's cuts using the same source time ranges (a separately recorded but synced
    /// source, e.g. an OBS facecam next to gameplay), so cutting the commentary keeps both in sync.
    case linked
}

public enum ReframeMode: String, Codable, Sendable {
    case none
    /// Keep the largest face in frame.
    case face
    /// Keep the visually salient region in frame.
    case saliency
}

public struct Slot: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var role: SlotRole
    public var fill: SlotFill
    public var transform: Transform
    public var reframe: ReframeMode
    /// Whether this slot's audio is used (speech) and drives silence cutting.
    public var useAudio: Bool
    public var audioGain: Double
    /// Layout to use when this is the only visual slot that received clips (e.g. gameplay goes full-frame
    /// when there is no facecam).
    public var aloneTransform: Transform?
    /// Optional slots may stay empty without a warning.
    public var optional: Bool

    public init(id: String, name: String, role: SlotRole, fill: SlotFill = .sequence, transform: Transform = .fullFrame,
                reframe: ReframeMode = .none, useAudio: Bool = true, audioGain: Double = 0,
                aloneTransform: Transform? = nil, optional: Bool = false) {
        self.id = id; self.name = name; self.role = role; self.fill = fill; self.transform = transform
        self.reframe = reframe; self.useAudio = useAudio; self.audioGain = audioGain
        self.aloneTransform = aloneTransform; self.optional = optional
    }
}

/// A fixed element of the template (title, branding bar, watermark…). `text` may contain `{title}`.
public struct TemplateElement: Codable, Sendable, Equatable {
    public enum Timing: Codable, Sendable, Equatable {
        case whole
        case opening(seconds: Double)
        case closing(seconds: Double)
    }
    public var id: String
    public var track: TrackKind
    public var content: ItemContent
    public var transform: Transform
    public var timing: Timing
    public var fadeIn: Double
    public var fadeOut: Double

    public init(id: String, track: TrackKind, content: ItemContent, transform: Transform = .fullFrame,
                timing: Timing = .whole, fadeIn: Double = 0, fadeOut: Double = 0) {
        self.id = id; self.track = track; self.content = content; self.transform = transform
        self.timing = timing; self.fadeIn = fadeIn; self.fadeOut = fadeOut
    }
}

// MARK: - Rules

public struct SilenceCutRule: Codable, Sendable, Equatable {
    /// Pauses longer than this (seconds) are cut.
    public var minGap: Double
    /// Audio kept before/after speech at each cut.
    public var padBefore: Double
    public var padAfter: Double
    public var removeFillers: Bool
    /// Pauses up to `speedUp.maxPause` are played fast instead of cut, so the footage stays continuous. Off when nil.
    public var speedUp: SpeedUpRule?
    public init(minGap: Double = 0.4, padBefore: Double = 0.08, padAfter: Double = 0.12, removeFillers: Bool = true,
                speedUp: SpeedUpRule? = nil) {
        self.minGap = minGap; self.padBefore = padBefore; self.padAfter = padAfter; self.removeFillers = removeFillers
        self.speedUp = speedUp
    }
}

public struct SpeedUpRule: Codable, Sendable, Equatable {
    /// Pauses up to this long (seconds) are kept and played fast; longer ones are cut as before.
    public var maxPause: Double
    /// Playback rate for the kept pause.
    public var rate: Double
    public init(maxPause: Double = 1.5, rate: Double = 2.5) { self.maxPause = maxPause; self.rate = rate }
}

public struct BeatCutRule: Codable, Sendable, Equatable {
    /// Change clip every N beats (montage pacing).
    public var everyBeats: Int
    /// Max distance (seconds) a cut may move to land on a beat.
    public var tolerance: Double
    public var minClip: Double
    public init(everyBeats: Int = 4, tolerance: Double = 0.15, minClip: Double = 0.8) {
        self.everyBeats = everyBeats; self.tolerance = tolerance; self.minClip = minClip
    }
}

public struct BeatSnapRule: Codable, Sendable, Equatable {
    /// Max distance (seconds) a speech cut may move to land on a beat.
    public var tolerance: Double
    public init(tolerance: Double = 0.15) { self.tolerance = tolerance }
}

public struct PunchInRule: Codable, Sendable, Equatable {
    public var zoom: Double
    /// Minimum seconds between zoom changes.
    public var minSpacing: Double
    /// Seconds over which the zoom eases in.
    public var rampDuration: Double
    /// Longest stretch, in seconds, with no cut and no zoom change before a pacing move is added. 0 turns pacing
    /// moves off; values below `minSpacing` behave as `minSpacing`.
    public var maxStill: Double
    public init(zoom: Double = 1.15, minSpacing: Double = 5, rampDuration: Double = 0.25, maxStill: Double = 6) {
        self.zoom = zoom; self.minSpacing = minSpacing; self.rampDuration = rampDuration; self.maxStill = maxStill
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        zoom = try c.decode(Double.self, forKey: .zoom)
        minSpacing = try c.decode(Double.self, forKey: .minSpacing)
        rampDuration = try c.decode(Double.self, forKey: .rampDuration)
        maxStill = try c.decodeIfPresent(Double.self, forKey: .maxStill) ?? 6
    }
}

public enum TakePolicy: String, Codable, Sendable {
    /// The last complete take: people stop recording when they are happy.
    case last
    /// Fewest fillers, steadiest pace, highest transcription confidence. Ties go to the later take.
    case best
}

/// Speech clean-up decided from the transcript before cutting. Keys missing from JSON take the defaults, so `{}`
/// turns every edit on.
public struct SpeechEditRule: Codable, Sendable, Equatable {
    /// Which take of a line recorded several times survives; nil (JSON `null`) keeps every take.
    public var takes: TakePolicy?
    /// Cut stutters ("the the", "I, I think") and restarts ("So the, so the main thing is").
    public var falseStarts: Bool
    public init(takes: TakePolicy? = .last, falseStarts: Bool = true) { self.takes = takes; self.falseStarts = falseStarts }

    enum CodingKeys: String, CodingKey { case takes, falseStarts }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        takes = c.contains(.takes) ? try c.decodeIfPresent(TakePolicy.self, forKey: .takes) : .last
        falseStarts = try c.decodeIfPresent(Bool.self, forKey: .falseStarts) ?? true
    }
    /// Writes `takes` even when nil, so "keep every take" does not read back as the default.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(takes, forKey: .takes)
        try c.encode(falseStarts, forKey: .falseStarts)
    }
}

public struct DuckRule: Codable, Sendable, Equatable {
    /// How far music drops under speech, in dB (positive number).
    public var depth: Double
    public var attack: Double
    public var release: Double
    public init(depth: Double = 12, attack: Double = 0.15, release: Double = 0.4) {
        self.depth = depth; self.attack = attack; self.release = release
    }
}

/// A cold open: the LLM brief's hook sentence plays first, then the draft runs from the top without it. Needs a brief;
/// there is no heuristic fallback, since a wrong cold open is worse than none.
public struct HookRule: Codable, Sendable, Equatable {
    /// Longest hook, in timeline seconds, worth moving.
    public var maxSeconds: Double
    /// Lowest importance the brief may give the hook sentence, when it scores sentences.
    public var minImportance: Double
    public init(maxSeconds: Double = 4, minImportance: Double = 0.6) { self.maxSeconds = maxSeconds; self.minImportance = minImportance }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxSeconds = try c.decodeIfPresent(Double.self, forKey: .maxSeconds) ?? 4
        minImportance = try c.decodeIfPresent(Double.self, forKey: .minImportance) ?? 0.6
    }
}

public struct CaptionRule: Codable, Sendable, Equatable {
    public var style: String
    public init(style: String) { self.style = style }
}

public struct Rules: Codable, Sendable, Equatable {
    public var maxDuration: Double?
    /// Speech clean-up decided from the transcript before the silence cut; nil leaves the speech as recorded.
    public var speechEdits: SpeechEditRule?
    public var silenceCut: SilenceCutRule?
    public var beatCut: BeatCutRule?
    /// Speech cuts (not beat cuts) nudged onto the music's beats.
    public var beatSnap: BeatSnapRule?
    public var punchIn: PunchInRule?
    public var captions: CaptionRule?
    public var duck: DuckRule?
    public var loudnessTarget: Double?
    /// Clips without speech are trimmed to at most this long (their middle), e.g. travel B-roll.
    public var maxSilentClip: Double?
    public var hook: HookRule?

    public init(maxDuration: Double? = nil, speechEdits: SpeechEditRule? = nil, silenceCut: SilenceCutRule? = nil, beatCut: BeatCutRule? = nil,
                beatSnap: BeatSnapRule? = nil, punchIn: PunchInRule? = nil, captions: CaptionRule? = nil, duck: DuckRule? = nil, loudnessTarget: Double? = -14,
                maxSilentClip: Double? = nil, hook: HookRule? = nil) {
        self.maxDuration = maxDuration; self.speechEdits = speechEdits; self.silenceCut = silenceCut; self.beatCut = beatCut; self.beatSnap = beatSnap
        self.punchIn = punchIn
        self.captions = captions; self.duck = duck; self.loudnessTarget = loudnessTarget; self.maxSilentClip = maxSilentClip
        self.hook = hook
    }
}

public struct MusicPolicy: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var moods: [String]
    public var genres: [String]
    public var minBPM: Double?
    public var maxBPM: Double?
    /// Music level in dB before ducking.
    public var gain: Double
    public var fadeIn: Double
    public var fadeOut: Double
    public init(enabled: Bool = true, moods: [String] = [], genres: [String] = [], minBPM: Double? = nil, maxBPM: Double? = nil,
                gain: Double = -16, fadeIn: Double = 0.5, fadeOut: Double = 1.5) {
        self.enabled = enabled; self.moods = moods; self.genres = genres; self.minBPM = minBPM; self.maxBPM = maxBPM
        self.gain = gain; self.fadeIn = fadeIn; self.fadeOut = fadeOut
    }
}

/// A reusable recipe: canvas + slots (layout) + fixed elements + rules (behaviour) + styles.
public struct Template: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var version: Int
    public var name: String
    public var summary: String
    public var contentType: ContentType
    public var canvas: Canvas
    public var slots: [Slot]
    public var elements: [TemplateElement]
    public var rules: Rules
    public var styles: [String: TextStyle]
    public var music: MusicPolicy
    public var exportPreset: String

    public init(id: String, version: Int = 1, name: String, summary: String = "", contentType: ContentType, canvas: Canvas,
                slots: [Slot], elements: [TemplateElement] = [], rules: Rules = Rules(), styles: [String: TextStyle] = [:],
                music: MusicPolicy = MusicPolicy(), exportPreset: String = "shorts-1080x1920") {
        self.id = id; self.version = version; self.name = name; self.summary = summary; self.contentType = contentType
        self.canvas = canvas; self.slots = slots; self.elements = elements; self.rules = rules; self.styles = styles
        self.music = music; self.exportPreset = exportPreset
    }

    public var primarySlot: Slot? { slots.first { $0.role == .primary } }
}
