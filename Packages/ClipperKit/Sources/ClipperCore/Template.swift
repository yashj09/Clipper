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
    /// Keywords with an emoji show it after the word, at most one per page.
    public var emoji: Bool
    public init(style: String, emoji: Bool = false) { self.style = style; self.emoji = emoji }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = try c.decode(String.self, forKey: .style)
        emoji = try c.decodeIfPresent(Bool.self, forKey: .emoji) ?? false
    }
}

/// A keyword (name, place, organization, number, or noun with an emoji) shown large on its own for a moment.
public struct CalloutRule: Codable, Sendable, Equatable {
    public var seconds: Double
    /// Least time between two callouts' starts.
    public var minSpacing: Double
    public var style: String
    public init(seconds: Double = 1.6, minSpacing: Double = 8, style: String = "callout") {
        self.seconds = seconds; self.minSpacing = minSpacing; self.style = style
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seconds = try c.decodeIfPresent(Double.self, forKey: .seconds) ?? 1.6
        minSpacing = try c.decodeIfPresent(Double.self, forKey: .minSpacing) ?? 8
        style = try c.decodeIfPresent(String.self, forKey: .style) ?? "callout"
    }
}

/// Cutaways to the user's own clips where the speaker names what a clip shows (its name, tags or own keywords).
public struct BRollRule: Codable, Sendable, Equatable {
    public var seconds: Double
    /// Least time between two cutaways' starts.
    public var minSpacing: Double
    public var maxPerMinute: Int
    public init(seconds: Double = 2.5, minSpacing: Double = 6, maxPerMinute: Int = 4) {
        self.seconds = seconds; self.minSpacing = minSpacing; self.maxPerMinute = maxPerMinute
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = BRollRule()
        seconds = try c.decodeIfPresent(Double.self, forKey: .seconds) ?? d.seconds
        minSpacing = try c.decodeIfPresent(Double.self, forKey: .minSpacing) ?? d.minSpacing
        maxPerMinute = try c.decodeIfPresent(Int.self, forKey: .maxPerMinute) ?? d.maxPerMinute
    }
}

/// A starting grade on every clip that has measured colour (`ColorAdjust.suggested`).
public struct ColorRule: Codable, Sendable, Equatable {
    public var look: ColorAdjust.Look
    public init(look: ColorAdjust.Look = .natural) { self.look = look }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        look = try c.decodeIfPresent(ColorAdjust.Look.self, forKey: .look) ?? .natural
    }
}

/// Transitions added where the footage jumps. Each part is off when nil.
public struct TransitionRule: Codable, Sendable, Equatable {
    /// Into the first item at or after each "Chapter: …" marker, when that item starts on a cut.
    public var chapters: Transition.Kind?
    public var chapterSeconds: Double
    /// A cross dissolve on every N-th cut.
    public var montageEvery: Int?
    public var montageSeconds: Double
    public init(chapters: Transition.Kind? = .dipToBlack, chapterSeconds: Double = 0.4, montageEvery: Int? = 4, montageSeconds: Double = 0.3) {
        self.chapters = chapters; self.chapterSeconds = chapterSeconds; self.montageEvery = montageEvery; self.montageSeconds = montageSeconds
    }

    enum CodingKeys: String, CodingKey { case chapters, chapterSeconds, montageEvery, montageSeconds }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chapters = c.contains(.chapters) ? try c.decodeIfPresent(Transition.Kind.self, forKey: .chapters) : .dipToBlack
        chapterSeconds = try c.decodeIfPresent(Double.self, forKey: .chapterSeconds) ?? 0.4
        montageEvery = c.contains(.montageEvery) ? try c.decodeIfPresent(Int.self, forKey: .montageEvery) : 4
        montageSeconds = try c.decodeIfPresent(Double.self, forKey: .montageSeconds) ?? 0.3
    }
    /// Writes the parts even when nil, so "off" does not read back as the default.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(chapters, forKey: .chapters); try c.encode(chapterSeconds, forKey: .chapterSeconds)
        try c.encode(montageEvery, forKey: .montageEvery); try c.encode(montageSeconds, forKey: .montageSeconds)
    }
}

/// Sound effects on the draft's emphasis moments, on an "SFX" audio track. Each moment is off when nil.
public struct SFXRule: Codable, Sendable, Equatable {
    /// At each emphasis zoom (not pacing moves).
    public var onZoom: SoundEffect?
    public var onCallout: SoundEffect?
    /// Where the cold open cuts to the top of the draft.
    public var onHook: SoundEffect?
    /// dB, on files peaking at −6 dBFS. In the e2e clip a whoosh at −20 sat 27 dB under the word it lands on, too quiet
    /// to notice; at −10 it sits 13 to 17 dB under.
    public var gain: Double
    public init(onZoom: SoundEffect? = .whoosh, onCallout: SoundEffect? = .pop, onHook: SoundEffect? = .ding, gain: Double = -10) {
        self.onZoom = onZoom; self.onCallout = onCallout; self.onHook = onHook; self.gain = gain
    }

    enum CodingKeys: String, CodingKey { case onZoom, onCallout, onHook, gain }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func effect(_ key: CodingKeys, _ fallback: SoundEffect) throws -> SoundEffect? {
            c.contains(key) ? try c.decodeIfPresent(SoundEffect.self, forKey: key) : fallback
        }
        onZoom = try effect(.onZoom, .whoosh); onCallout = try effect(.onCallout, .pop); onHook = try effect(.onHook, .ding)
        gain = try c.decodeIfPresent(Double.self, forKey: .gain) ?? -10
    }
    /// Writes the moments even when nil, so "off" does not read back as the default.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(onZoom, forKey: .onZoom); try c.encode(onCallout, forKey: .onCallout); try c.encode(onHook, forKey: .onHook)
        try c.encode(gain, forKey: .gain)
    }
}

/// Footage dropped for being blurry or badly exposed, judged on the `.visual` samples (about one a second).
public struct BadShotRule: Codable, Sendable, Equatable {
    /// `VisualSample.sharpness` below this is blurry.
    public var minSharpness: Double
    /// `VisualSample.luma` outside this range is too dark or blown out.
    public var minLuma: Double
    public var maxLuma: Double
    /// Shortest bad stretch worth cutting.
    public var minSeconds: Double
    public init(minSharpness: Double = 0.15, minLuma: Double = 0.08, maxLuma: Double = 0.95, minSeconds: Double = 1.5) {
        self.minSharpness = minSharpness; self.minLuma = minLuma; self.maxLuma = maxLuma; self.minSeconds = minSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = BadShotRule()
        minSharpness = try c.decodeIfPresent(Double.self, forKey: .minSharpness) ?? d.minSharpness
        minLuma = try c.decodeIfPresent(Double.self, forKey: .minLuma) ?? d.minLuma
        maxLuma = try c.decodeIfPresent(Double.self, forKey: .maxLuma) ?? d.maxLuma
        minSeconds = try c.decodeIfPresent(Double.self, forKey: .minSeconds) ?? d.minSeconds
    }
}

/// Profanity in the transcript is silenced under the word and masked in the captions ("f***"). Off in every built-in:
/// it changes what the speaker said.
public struct ProfanityRule: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable { case mute, bleep }
    /// `bleep` plays a tone over the silenced word when the library has the effect, and mutes otherwise.
    public var action: Action
    public init(action: Action = .mute) { self.action = action }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = try c.decodeIfPresent(Action.self, forKey: .action) ?? .mute
    }
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
    public var callouts: CalloutRule?
    /// With it, `.broll` slots hold candidates for cutaways instead of being laid out by their fill.
    public var broll: BRollRule?
    public var color: ColorRule?
    public var transitions: TransitionRule?
    public var sfx: SFXRule?
    public var badShots: BadShotRule?
    public var profanity: ProfanityRule?

    public init(maxDuration: Double? = nil, speechEdits: SpeechEditRule? = nil, silenceCut: SilenceCutRule? = nil, beatCut: BeatCutRule? = nil,
                beatSnap: BeatSnapRule? = nil, punchIn: PunchInRule? = nil, captions: CaptionRule? = nil, duck: DuckRule? = nil, loudnessTarget: Double? = -14,
                maxSilentClip: Double? = nil, hook: HookRule? = nil, callouts: CalloutRule? = nil, broll: BRollRule? = nil,
                color: ColorRule? = nil, transitions: TransitionRule? = nil, sfx: SFXRule? = nil, badShots: BadShotRule? = nil, profanity: ProfanityRule? = nil) {
        self.maxDuration = maxDuration; self.speechEdits = speechEdits; self.silenceCut = silenceCut; self.beatCut = beatCut; self.beatSnap = beatSnap
        self.punchIn = punchIn
        self.captions = captions; self.duck = duck; self.loudnessTarget = loudnessTarget; self.maxSilentClip = maxSilentClip
        self.hook = hook; self.callouts = callouts; self.broll = broll
        self.color = color; self.transitions = transitions; self.sfx = sfx; self.badShots = badShots
        self.profanity = profanity
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
