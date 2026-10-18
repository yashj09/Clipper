import Foundation

public typealias ItemID = UUID
public typealias TrackID = UUID
public typealias AssetID = UUID

/// Output frame geometry and rate. Every layer's transform is normalized against this.
public struct Canvas: Codable, Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var frameRate: FrameRate

    public init(width: Int, height: Int, frameRate: FrameRate = .fps30) {
        self.width = width; self.height = height; self.frameRate = frameRate
    }

    public static let vertical1080 = Canvas(width: 1080, height: 1920)
    public static let landscape1080 = Canvas(width: 1920, height: 1080)
    public static let square1080 = Canvas(width: 1080, height: 1080)
    public static let portrait4x5 = Canvas(width: 1080, height: 1350)

    public var aspect: Double { Double(width) / Double(height) }
}

/// How content is fitted into its box before zoom/rotation.
public enum FitMode: String, Codable, Sendable {
    /// Cover the box, cropping the overflow around `focus`.
    case fill
    /// Fit entirely inside the box (letterbox).
    case fit
    /// Ignore aspect ratio.
    case stretch
}

/// Placement of a visual item. The *box* is the item's frame on the canvas; content is fitted into it.
/// `zoom` and `focus` operate inside the box (punch-ins, reframing), `scale`/`rotation` transform the box.
public struct Transform: Codable, Sendable, Equatable {
    /// Box size relative to the canvas.
    public var box: NormSize
    /// Box centre on the canvas.
    public var position: Param<NormPoint>
    /// Scales the whole box (e.g. pop-in animation of an overlay).
    public var scale: Param<Double>
    /// Rotation of the box, in degrees clockwise.
    public var rotation: Param<Double>
    /// Zoom of the content inside the box (≥ 1 crops tighter). Punch-ins animate this.
    public var zoom: Param<Double>
    /// Source-space point kept centred when content overflows the box. Reframing animates this.
    public var focus: Param<NormPoint>
    /// Static crop of the source before fitting.
    public var crop: NormRect
    public var fit: FitMode
    /// Mirror the content left↔right / top↔bottom inside its box.
    public var flipH: Bool
    public var flipV: Bool

    public init(box: NormSize = .full, position: Param<NormPoint> = .constant(.center), scale: Param<Double> = .constant(1),
                rotation: Param<Double> = .constant(0), zoom: Param<Double> = .constant(1),
                focus: Param<NormPoint> = .constant(.center), crop: NormRect = .full, fit: FitMode = .fill,
                flipH: Bool = false, flipV: Bool = false) {
        self.box = box; self.position = position; self.scale = scale; self.rotation = rotation
        self.zoom = zoom; self.focus = focus; self.crop = crop; self.fit = fit; self.flipH = flipH; self.flipV = flipV
    }

    public static let fullFrame = Transform()

    private enum CodingKeys: String, CodingKey { case box, position, scale, rotation, zoom, focus, crop, fit, flipH, flipV }

    // Flips are stored only when on, so documents written before they existed decode, and plain ones stay unchanged.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        box = try c.decode(NormSize.self, forKey: .box)
        position = try c.decode(Param<NormPoint>.self, forKey: .position)
        scale = try c.decode(Param<Double>.self, forKey: .scale)
        rotation = try c.decode(Param<Double>.self, forKey: .rotation)
        zoom = try c.decode(Param<Double>.self, forKey: .zoom)
        focus = try c.decode(Param<NormPoint>.self, forKey: .focus)
        crop = try c.decode(NormRect.self, forKey: .crop)
        fit = try c.decode(FitMode.self, forKey: .fit)
        flipH = try c.decodeIfPresent(Bool.self, forKey: .flipH) ?? false
        flipV = try c.decodeIfPresent(Bool.self, forKey: .flipV) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(box, forKey: .box); try c.encode(position, forKey: .position); try c.encode(scale, forKey: .scale)
        try c.encode(rotation, forKey: .rotation); try c.encode(zoom, forKey: .zoom); try c.encode(focus, forKey: .focus)
        try c.encode(crop, forKey: .crop); try c.encode(fit, forKey: .fit)
        if flipH { try c.encode(true, forKey: .flipH) }
        if flipV { try c.encode(true, forKey: .flipV) }
    }
}

/// Basic colour correction (Premiere's Lumetri basics), applied after HDR tone mapping. Zero everywhere = untouched.
public struct ColorAdjust: Codable, Sendable, Equatable, Hashable {
    /// Stops, −3…3.
    public var exposure: Double = 0
    /// −1…1 for every other control.
    public var contrast: Double = 0
    public var highlights: Double = 0
    public var shadows: Double = 0
    public var saturation: Double = 0
    /// Warmer (+) or cooler (−) white balance.
    public var temperature: Double = 0
    /// Magenta (+) or green (−).
    public var tint: Double = 0

    public init(exposure: Double = 0, contrast: Double = 0, highlights: Double = 0, shadows: Double = 0, saturation: Double = 0,
                temperature: Double = 0, tint: Double = 0) {
        self.exposure = exposure; self.contrast = contrast; self.highlights = highlights; self.shadows = shadows
        self.saturation = saturation; self.temperature = temperature; self.tint = tint
    }

    public static let none = ColorAdjust()
    public var isNone: Bool { self == .none }

    /// One-click starting points ("looks"), refined with the sliders.
    public static let looks: [(name: String, adjust: ColorAdjust)] = [
        ("Warm", ColorAdjust(contrast: 0.05, saturation: 0.1, temperature: 0.35, tint: 0.05)),
        ("Cool", ColorAdjust(contrast: 0.05, temperature: -0.35)),
        ("Vivid", ColorAdjust(contrast: 0.2, shadows: -0.05, saturation: 0.35)),
        ("Matte", ColorAdjust(contrast: -0.25, highlights: -0.15, shadows: 0.25, saturation: -0.15)),
        ("Cinematic", ColorAdjust(contrast: 0.25, highlights: -0.2, shadows: -0.1, saturation: -0.1, temperature: 0.1, tint: -0.05)),
        ("Bright", ColorAdjust(exposure: 0.4, shadows: 0.15, saturation: 0.05)),
        ("Black & White", ColorAdjust(contrast: 0.15, saturation: -1)),
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = ColorAdjust()
        exposure = c.value(.exposure, d.exposure); contrast = c.value(.contrast, d.contrast)
        highlights = c.value(.highlights, d.highlights); shadows = c.value(.shadows, d.shadows)
        saturation = c.value(.saturation, d.saturation); temperature = c.value(.temperature, d.temperature)
        tint = c.value(.tint, d.tint)
    }
}

extension ColorAdjust {
    /// A starting grade picked for a clip from its measured colour. `none` leaves the clip untouched.
    public enum Look: String, Codable, Sendable, CaseIterable { case natural, none }

    /// The adjustment that moves `stats` toward a neutral, well-exposed clip. Each control inverts the compositor's
    /// `color_adjust` (GPU.swift) for the statistic it moves. Rows run in order, and a later row measures through
    /// the earlier rows' result, so contrast sees the exposed range and saturation sees both.
    public static func suggested(for stats: ColorStats, look: Look = .natural) -> ColorAdjust {
        switch look {
        case .none: return .none
        case .natural: break
        }
        // Exposure scales display values by 2^(stops / 2.2) (it multiplies linear light, decoded with gamma 2.2).
        func gain(_ a: ColorAdjust) -> Double { pow(2, a.exposure / 2.2) }
        typealias Rule = (control: WritableKeyPath<ColorAdjust, Double>, measure: (ColorAdjust) -> Double, target: Double,
                          deadBand: Double, gain: Double, limit: Double, full: (_ measured: Double, _ target: Double) -> Double)
        let avg = (stats.r + stats.b) / 2
        let rules: [Rule] = [
            (\.exposure, { _ in stats.luma }, 0.45, 0.05, 0.8, 3, { m, t in 2.2 * log2(t / m) }),
            // Contrast scales values around 0.5 by (1 + c).
            (\.contrast, { a in min(1, stats.p99 * gain(a)) - min(1, stats.p01 * gain(a)) }, 0.9, 0.1, 0.5, 0.3,
             { m, t in t / m - 1 }),
            // Saturation scales chroma by (1 + s); exposure and contrast already scaled it.
            (\.saturation, { a in stats.saturation * gain(a) * (1 + a.contrast) }, 0.35, 0.05, 0.3, 0.2,
             { m, t in t / m - 1 }),
            // Temperature multiplies linear red by (1 + 0.2 t) and blue by (1 − 0.2 t): solved for equal means.
            (\.temperature, { _ in stats.r / max(stats.b, 1e-3) }, 1, 0.05, 0.3, 0.25,
             { m, t in let q = pow(t / m, 2.2); return 5 * (q - 1) / (q + 1) }),
            // Tint multiplies linear green by (1 − 0.15 tint): solved for green equal to the red/blue mean.
            (\.tint, { _ in stats.g / max(avg, 1e-3) }, 1, 0.05, 0.3, 0.15,
             { m, t in (1 - pow(t / m, 2.2)) / 0.15 }),
        ]
        var adjust = ColorAdjust()
        for rule in rules {
            let measured = max(rule.measure(adjust), 1e-3)
            guard abs(measured - rule.target) > rule.deadBand else { continue }
            var value = min(max(rule.gain * rule.full(measured, rule.target), -rule.limit), rule.limit)
            // Dull footage gets a lift; vivid footage (a sunset, neon) is a choice, not a fault, so it is never pulled down.
            if rule.control == \.saturation { value = max(value, 0) }
            adjust[keyPath: rule.control] = (value * 100).rounded() / 100
        }
        return adjust
    }
}

/// How a layer combines with what's below it.
public enum BlendMode: String, Codable, Sendable, CaseIterable {
    case normal, add, screen, multiply
}

/// A transition into an item from the one before it on the same track. It starts at the cut: the outgoing clip keeps
/// playing past its out-point (from its media handle, or its last frame held) while the incoming one fades in.
public struct Transition: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case crossDissolve, dipToBlack, dipToWhite
    }
    public var kind: Kind
    public var duration: RationalTime
    public init(_ kind: Kind, duration: RationalTime) { self.kind = kind; self.duration = duration }
}

/// Where an item came from. Automation only replaces `.auto` items that the user hasn't locked.
public enum Origin: Sendable, Equatable, Codable {
    case user
    case auto(pass: String)

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        self = s == "user" ? .user : .auto(pass: String(s.dropFirst("auto:".count)))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .user: try c.encode("user")
        case .auto(let pass): try c.encode("auto:\(pass)")
        }
    }

    public var isAuto: Bool { if case .auto = self { true } else { false } }
}

public struct MediaRef: Codable, Sendable, Equatable {
    public var asset: AssetID
    /// Range in the source media. Its duration equals the item's timeline duration × `speed`.
    public var source: TimeRange
    public var speed: Double
    public var useAudio: Bool

    public init(asset: AssetID, source: TimeRange, speed: Double = 1, useAudio: Bool = true) {
        self.asset = asset; self.source = source; self.speed = speed; self.useAudio = useAudio
    }
}

public struct TextContent: Codable, Sendable, Equatable {
    public var text: String
    public var style: String
    public init(text: String, style: String) { self.text = text; self.style = style }
}

/// One caption "page": the words shown together, each with item-relative timing for highlighting.
public struct CaptionContent: Codable, Sendable, Equatable {
    public struct Word: Codable, Sendable, Equatable {
        public var text: String
        /// Relative to the caption item's start.
        public var start: RationalTime
        public var end: RationalTime
        public var emphasis: Bool
        public init(text: String, start: RationalTime, end: RationalTime, emphasis: Bool = false) {
            self.text = text; self.start = start; self.end = end; self.emphasis = emphasis
        }
    }
    public var words: [Word]
    public var style: String
    public init(words: [Word], style: String) { self.words = words; self.style = style }
    public var text: String { words.map(\.text).joined(separator: " ") }
}

public enum ItemContent: Sendable, Equatable {
    case media(MediaRef)
    case text(TextContent)
    case caption(CaptionContent)
    case image(AssetID)
    case solid(RGBA)

    public var mediaRef: MediaRef? { if case .media(let m) = self { m } else { nil } }
    public var isVisual: Bool { true }
}

extension ItemContent: Codable {
    private enum Keys: String, CodingKey { case type, media, text, caption, image, solid }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "media": self = .media(try c.decode(MediaRef.self, forKey: .media))
        case "text": self = .text(try c.decode(TextContent.self, forKey: .text))
        case "caption": self = .caption(try c.decode(CaptionContent.self, forKey: .caption))
        case "image": self = .image(try c.decode(AssetID.self, forKey: .image))
        case "solid": self = .solid(try c.decode(RGBA.self, forKey: .solid))
        case let t: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown item type \(t)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .media(let m): try c.encode("media", forKey: .type); try c.encode(m, forKey: .media)
        case .text(let t): try c.encode("text", forKey: .type); try c.encode(t, forKey: .text)
        case .caption(let cap): try c.encode("caption", forKey: .type); try c.encode(cap, forKey: .caption)
        case .image(let a): try c.encode("image", forKey: .type); try c.encode(a, forKey: .image)
        case .solid(let col): try c.encode("solid", forKey: .type); try c.encode(col, forKey: .solid)
        }
    }
}

public struct Item: Codable, Sendable, Equatable, Identifiable {
    public var id: ItemID
    public var name: String
    /// Placement on the timeline.
    public var range: TimeRange
    public var content: ItemContent
    public var transform: Transform
    public var opacity: Param<Double>
    /// Audio gain in dB (0 = unity). Ducking writes keyframes here.
    public var gain: Param<Double>
    public var fadeIn: RationalTime
    public var fadeOut: RationalTime
    public var origin: Origin
    /// Locked items are never modified by automation re-runs.
    public var locked: Bool
    /// Template slot this item fills, if any.
    public var slot: String?
    /// Disabled items stay on the timeline but aren't seen or heard (Premiere's Enable).
    public var enabled: Bool
    public var color: ColorAdjust
    public var blend: BlendMode
    /// Transition from the previous item on the track into this one.
    public var transition: Transition?

    public init(id: ItemID = UUID(), name: String = "", range: TimeRange, content: ItemContent,
                transform: Transform = .fullFrame, opacity: Param<Double> = .constant(1), gain: Param<Double> = .constant(0),
                fadeIn: RationalTime = .zero, fadeOut: RationalTime = .zero, origin: Origin = .user,
                locked: Bool = false, slot: String? = nil, enabled: Bool = true, color: ColorAdjust = .none,
                blend: BlendMode = .normal, transition: Transition? = nil) {
        self.id = id; self.name = name; self.range = range; self.content = content; self.transform = transform
        self.opacity = opacity; self.gain = gain; self.fadeIn = fadeIn; self.fadeOut = fadeOut
        self.origin = origin; self.locked = locked; self.slot = slot
        self.enabled = enabled; self.color = color; self.blend = blend; self.transition = transition
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, range, content, transform, opacity, gain, fadeIn, fadeOut, origin, locked, slot, enabled, color, blend, transition
    }

    // The editing fields added after the first document version are stored only when they differ from the defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ItemID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        range = try c.decode(TimeRange.self, forKey: .range)
        content = try c.decode(ItemContent.self, forKey: .content)
        transform = try c.decode(Transform.self, forKey: .transform)
        opacity = try c.decode(Param<Double>.self, forKey: .opacity)
        gain = try c.decode(Param<Double>.self, forKey: .gain)
        fadeIn = try c.decode(RationalTime.self, forKey: .fadeIn)
        fadeOut = try c.decode(RationalTime.self, forKey: .fadeOut)
        origin = try c.decode(Origin.self, forKey: .origin)
        locked = try c.decode(Bool.self, forKey: .locked)
        slot = try c.decodeIfPresent(String.self, forKey: .slot)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        color = try c.decodeIfPresent(ColorAdjust.self, forKey: .color) ?? .none
        blend = try c.decodeIfPresent(BlendMode.self, forKey: .blend) ?? .normal
        transition = try c.decodeIfPresent(Transition.self, forKey: .transition)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(range, forKey: .range)
        try c.encode(content, forKey: .content); try c.encode(transform, forKey: .transform); try c.encode(opacity, forKey: .opacity)
        try c.encode(gain, forKey: .gain); try c.encode(fadeIn, forKey: .fadeIn); try c.encode(fadeOut, forKey: .fadeOut)
        try c.encode(origin, forKey: .origin); try c.encode(locked, forKey: .locked)
        try c.encodeIfPresent(slot, forKey: .slot)
        if !enabled { try c.encode(false, forKey: .enabled) }
        if !color.isNone { try c.encode(color, forKey: .color) }
        if blend != .normal { try c.encode(blend, forKey: .blend) }
        try c.encodeIfPresent(transition, forKey: .transition)
    }

    public var start: RationalTime { range.start }
    public var end: RationalTime { range.end }

    /// Maps a timeline time inside this item to source media time (for `.media` items).
    public func sourceTime(at timelineTime: RationalTime) -> RationalTime? {
        guard let m = content.mediaRef else { return nil }
        return m.source.start + (timelineTime - range.start).timesSpeed(m.speed)
    }
}

public enum TrackKind: String, Codable, Sendable, CaseIterable {
    case video, audio, music, title, overlay, caption

    public var isVisual: Bool { self != .audio && self != .music }
    public var hasAudio: Bool { self == .video || self == .audio || self == .music }
}

public struct Track: Codable, Sendable, Equatable, Identifiable {
    public var id: TrackID
    public var kind: TrackKind
    public var name: String
    /// Sorted by start time; items never overlap on a track.
    public var items: [Item]
    public var muted: Bool
    public var hidden: Bool
    public var locked: Bool
    /// Track gain in dB.
    public var gain: Double
    /// BCP-47 language of a caption track's text (e.g. "en", "es", "zh-Hant"); nil = unknown / not applicable.
    /// Language-tagged caption tracks also export as `<name>.<language>.srt|vtt|ass` sidecars, even when hidden.
    /// Optional, so documents written before it existed decode unchanged (missing key → nil, nil is never encoded).
    public var language: String?

    public init(id: TrackID = UUID(), kind: TrackKind, name: String? = nil, items: [Item] = [],
                muted: Bool = false, hidden: Bool = false, locked: Bool = false, gain: Double = 0, language: String? = nil) {
        self.id = id; self.kind = kind; self.name = name ?? kind.rawValue.capitalized; self.items = items
        self.muted = muted; self.hidden = hidden; self.locked = locked; self.gain = gain; self.language = language
    }

    public var end: RationalTime { items.map(\.end).max() ?? .zero }

    public func index(of id: ItemID) -> Int? { items.firstIndex { $0.id == id } }

    /// Items intersecting `range`, using binary search on the sorted item list.
    public func items(in range: TimeRange) -> ArraySlice<Item> {
        var lo = 0, hi = items.count
        while lo < hi { let m = (lo + hi) / 2; if items[m].end <= range.start { lo = m + 1 } else { hi = m } }
        var e = lo
        while e < items.count, items[e].start < range.end { e += 1 }
        return items[lo..<e]
    }

    public mutating func sortItems() { items.sort { $0.start < $1.start } }
}

/// What produced a timeline, so drafts can be re-run and compared.
public struct Provenance: Codable, Sendable, Equatable {
    public var template: String
    public var templateVersion: Int
    public var seed: UInt64
    public var passes: [String]
    /// The draft's inputs, for re-drafting. Optional: timelines drafted before it existed decode without it.
    public var inputs: DraftRecord?
    public init(template: String, templateVersion: Int, seed: UInt64, passes: [String], inputs: DraftRecord? = nil) {
        self.template = template; self.templateVersion = templateVersion; self.seed = seed; self.passes = passes
        self.inputs = inputs
    }
}

/// The user-facing inputs of a draft (clips per slot and the draft options), enough to run it again.
public struct DraftRecord: Codable, Sendable, Equatable {
    public struct Clip: Codable, Sendable, Equatable {
        public var asset: AssetID
        /// nil = the template's primary slot.
        public var slot: String?
        /// Trim of the source in seconds (highlights use these).
        public var inPoint: Double?
        public var outPoint: Double?
        public init(asset: AssetID, slot: String? = nil, inPoint: Double? = nil, outPoint: Double? = nil) {
            self.asset = asset; self.slot = slot; self.inPoint = inPoint; self.outPoint = outPoint
        }
    }
    public var clips: [Clip]
    public var title: String?
    public var captions: Bool?
    public var music: Bool?
    public var maxDuration: Double?
    public var musicID: String?
    public init(clips: [Clip], title: String? = nil, captions: Bool? = nil, music: Bool? = nil, maxDuration: Double? = nil,
                musicID: String? = nil) {
        self.clips = clips; self.title = title; self.captions = captions; self.music = music
        self.maxDuration = maxDuration; self.musicID = musicID
    }
}

/// A named point on the timeline.
public struct Marker: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var time: RationalTime
    public var name: String
    public init(id: UUID = UUID(), time: RationalTime, name: String = "") { self.id = id; self.time = time; self.name = name }
}

/// What a draft knows about the video for publishing (from the transcript brief), beyond its name.
public struct TimelineMetadata: Codable, Sendable, Equatable {
    public var description: String?
    /// Without "#".
    public var hashtags: [String]
    public init(description: String? = nil, hashtags: [String] = []) { self.description = description; self.hashtags = hashtags }
}

/// The editable document: tracks bottom-to-top (index 0 is drawn first).
public struct Timeline: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var canvas: Canvas
    public var tracks: [Track]
    /// Text styles available to text and caption items (template styles merged with built-ins).
    public var styles: [String: TextStyle]
    /// Integrated loudness target for export, in LUFS.
    public var loudnessTarget: Double?
    /// Credits required by licences of used media (e.g. CC-BY music).
    public var attributions: [String]
    public var provenance: Provenance?
    /// Markers (M), sorted by time.
    public var markers: [Marker]
    public var metadata: TimelineMetadata?

    public init(id: UUID = UUID(), name: String, canvas: Canvas, tracks: [Track] = [], styles: [String: TextStyle] = [:],
                loudnessTarget: Double? = -14, attributions: [String] = [], provenance: Provenance? = nil, markers: [Marker] = [],
                metadata: TimelineMetadata? = nil) {
        self.id = id; self.name = name; self.canvas = canvas; self.tracks = tracks; self.styles = styles
        self.loudnessTarget = loudnessTarget; self.attributions = attributions; self.provenance = provenance
        self.markers = markers; self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, canvas, tracks, styles, loudnessTarget, attributions, provenance, markers, metadata
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        canvas = try c.decode(Canvas.self, forKey: .canvas)
        tracks = try c.decode([Track].self, forKey: .tracks)
        styles = try c.decode([String: TextStyle].self, forKey: .styles)
        loudnessTarget = try c.decodeIfPresent(Double.self, forKey: .loudnessTarget)
        attributions = try c.decode([String].self, forKey: .attributions)
        provenance = try c.decodeIfPresent(Provenance.self, forKey: .provenance)
        markers = try c.decodeIfPresent([Marker].self, forKey: .markers) ?? []
        metadata = try c.decodeIfPresent(TimelineMetadata.self, forKey: .metadata)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(canvas, forKey: .canvas)
        try c.encode(tracks, forKey: .tracks); try c.encode(styles, forKey: .styles)
        try c.encodeIfPresent(loudnessTarget, forKey: .loudnessTarget)
        try c.encode(attributions, forKey: .attributions)
        try c.encodeIfPresent(provenance, forKey: .provenance)
        if !markers.isEmpty { try c.encode(markers, forKey: .markers) }
        try c.encodeIfPresent(metadata, forKey: .metadata)
    }

    public var duration: RationalTime { tracks.map(\.end).max() ?? .zero }

    public func trackIndex(_ id: TrackID) -> Int? { tracks.firstIndex { $0.id == id } }

    /// Locates an item by ID: (track index, item index).
    public func locate(_ id: ItemID) -> (track: Int, item: Int)? {
        for (ti, t) in tracks.enumerated() { if let ii = t.index(of: id) { return (ti, ii) } }
        return nil
    }

    public func item(_ id: ItemID) -> Item? { locate(id).map { tracks[$0.track].items[$0.item] } }

    public var allItems: [Item] { tracks.flatMap(\.items) }

    public func tracks(of kind: TrackKind) -> [Track] { tracks.filter { $0.kind == kind } }
}
