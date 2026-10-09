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

    public init(id: String, name: String, role: SlotRole, fill: SlotFill = .sequence, transform: Transform = .fullFrame,
                reframe: ReframeMode = .none, useAudio: Bool = true, audioGain: Double = 0) {
        self.id = id; self.name = name; self.role = role; self.fill = fill; self.transform = transform
        self.reframe = reframe; self.useAudio = useAudio; self.audioGain = audioGain
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
    public init(minGap: Double = 0.4, padBefore: Double = 0.08, padAfter: Double = 0.12, removeFillers: Bool = true) {
        self.minGap = minGap; self.padBefore = padBefore; self.padAfter = padAfter; self.removeFillers = removeFillers
    }
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

public struct PunchInRule: Codable, Sendable, Equatable {
    public var zoom: Double
    /// Minimum seconds between punch-ins.
    public var minSpacing: Double
    /// Seconds over which the zoom eases in.
    public var rampDuration: Double
    public init(zoom: Double = 1.15, minSpacing: Double = 5, rampDuration: Double = 0.25) {
        self.zoom = zoom; self.minSpacing = minSpacing; self.rampDuration = rampDuration
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

public struct CaptionRule: Codable, Sendable, Equatable {
    public var style: String
    public init(style: String) { self.style = style }
}

public struct Rules: Codable, Sendable, Equatable {
    public var maxDuration: Double?
    public var silenceCut: SilenceCutRule?
    public var beatCut: BeatCutRule?
    public var punchIn: PunchInRule?
    public var captions: CaptionRule?
    public var duck: DuckRule?
    public var loudnessTarget: Double?

    public init(maxDuration: Double? = nil, silenceCut: SilenceCutRule? = nil, beatCut: BeatCutRule? = nil,
                punchIn: PunchInRule? = nil, captions: CaptionRule? = nil, duck: DuckRule? = nil, loudnessTarget: Double? = -14) {
        self.maxDuration = maxDuration; self.silenceCut = silenceCut; self.beatCut = beatCut; self.punchIn = punchIn
        self.captions = captions; self.duck = duck; self.loudnessTarget = loudnessTarget
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
