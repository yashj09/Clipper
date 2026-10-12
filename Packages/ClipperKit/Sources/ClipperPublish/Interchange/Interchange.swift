import ClipperCore
import Foundation

// Round-trip ("interchange") export: hands a Clipper timeline to pro editors as FCPXML (Final Cut Pro, DaVinci
// Resolve, Premiere via converters) or OpenTimelineIO JSON. Both exporters are pure: (timeline, assets) → bytes.

/// Errors thrown by the interchange exporters.
public enum InterchangeError: Error, Equatable, LocalizedError {
    /// An item references an asset that isn't in the `assets` dictionary.
    case missingAsset(AssetID, item: ItemID)
    /// The canvas frame rate has a zero or negative numerator/denominator.
    case invalidFrameRate(FrameRate)

    public var errorDescription: String? {
        switch self {
        case .missingAsset(let asset, let item): "Item \(item) uses media \(asset), which isn't in the library."
        case .invalidFrameRate(let rate): "The timeline frame rate \(rate.numerator)/\(rate.denominator) is invalid."
        }
    }
}

/// A timeline → file exporter for another editor.
public protocol TimelineInterchangeExporter: Sendable {
    /// File extension without the dot ("fcpxml", "otio").
    static var fileExtension: String { get }
    func export(_ timeline: Timeline, assets: [AssetID: MediaAsset]) throws -> Data
}

extension TimelineInterchangeExporter {
    /// `"<projectName>.<ext>"` with path separators and control characters replaced.
    public static func suggestedFileName(projectName: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        var name = String(projectName.unicodeScalars.map { bad.contains($0) ? "-" : Character($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.hasPrefix(".") { name = "Clipper Timeline" + name }
        return name + "." + fileExtension
    }
}

extension Timeline {
    /// FCPXML for Final Cut Pro / DaVinci Resolve. See `FCPXMLExporter` for options.
    public func exportFCPXML(assets: [AssetID: MediaAsset], projectName: String? = nil) throws -> Data {
        try FCPXMLExporter(projectName: projectName).export(self, assets: assets)
    }

    /// OpenTimelineIO JSON (`.otio`).
    public func exportOTIO(assets: [AssetID: MediaAsset]) throws -> Data {
        try OTIOExporter().export(self, assets: assets)
    }
}

// MARK: - Shared internals

/// A frame grid `fps = num/den`. Positions are whole frames: frame `f` starts at `f·den/num` seconds.
struct FrameGrid: Equatable {
    let num: Int64
    let den: Int64

    init(_ rate: FrameRate) { num = Int64(rate.numerator); den = Int64(rate.denominator) }
    init(num: Int64, den: Int64) { self.num = num; self.den = den }

    var isValid: Bool { num > 0 && den > 0 }
    var fps: Double { Double(num) / Double(den) }

    /// Nearest frame to `t` (halves round away from zero).
    func frames(_ t: RationalTime) -> Int64 {
        // frames = t.value/t.scale · num/den
        let (n, o1) = t.value.multipliedReportingOverflow(by: num)
        let (d, o2) = Int64(t.scale).multipliedReportingOverflow(by: den)
        if o1 || o2 { return Int64((t.seconds * fps).rounded()) }
        return roundDiv(n, d)
    }

    /// Exact frame count when `t` lies on the grid.
    func exactFrames(_ t: RationalTime) -> Int64? {
        let (n, o1) = t.value.multipliedReportingOverflow(by: num)
        let (d, o2) = Int64(t.scale).multipliedReportingOverflow(by: den)
        guard !o1, !o2, n % d == 0 else { return nil }
        return n / d
    }

    /// Start of frame `frames`: `frames·den/num` seconds.
    func time(_ frames: Int64) -> RationalTime { RationalTime.exact(frames * den, num) }

    /// Frame count of `seconds` (fractional), for formats that store doubles (OTIO).
    func frameValue(_ t: RationalTime) -> Double { Double(t.value) * Double(num) / (Double(t.scale) * Double(den)) }
}

func roundDiv(_ n: Int64, _ d: Int64) -> Int64 {
    precondition(d > 0)
    return n >= 0 ? (n + d / 2) / d : -((-n + d / 2) / d)
}

func gcd64(_ a: Int64, _ b: Int64) -> Int64 {
    var (a, b) = (abs(a), abs(b))
    while b != 0 { (a, b) = (b, a % b) }
    return max(a, 1)
}

extension RationalTime {
    /// `value/scale` seconds reduced so the scale fits in Int32 (falls back to rounding at the default scale).
    static func exact(_ value: Int64, _ scale: Int64) -> RationalTime {
        let g = gcd64(value, scale)
        let v = value / g, s = scale / g
        if s <= Int64(Int32.max) { return RationalTime(value: v, scale: Int32(s)) }
        return RationalTime(seconds: Double(value) / Double(scale))
    }
}

enum InterchangeModel {
    /// Asset IDs used by the timeline in first-use order; throws for the first missing one.
    static func usedAssets(_ timeline: Timeline, _ assets: [AssetID: MediaAsset]) throws -> [MediaAsset] {
        var seen = Set<AssetID>(), out: [MediaAsset] = []
        for track in timeline.tracks {
            for item in track.items {
                let id: AssetID
                switch item.content {
                case .media(let m): id = m.asset
                case .image(let a): id = a
                default: continue
                }
                guard let asset = assets[id] else { throw InterchangeError.missingAsset(id, item: item.id) }
                if seen.insert(id).inserted { out.append(asset) }
            }
        }
        return out
    }

    /// The primary storyline: the explicit override if it exists, else the `.video` track whose items carry the most
    /// media time, else any visual track with media. Nil when no track has media.
    static func primaryTrackIndex(_ timeline: Timeline, override: TrackID?) -> Int? {
        if let override, let i = timeline.trackIndex(override) { return i }
        func mediaSeconds(_ t: Track) -> Double {
            t.items.reduce(0) { $0 + ($1.content.mediaRef != nil || isImage($1) ? $1.range.duration.seconds : 0) }
        }
        let ranked = timeline.tracks.indices.filter { mediaSeconds(timeline.tracks[$0]) > 0 }
        let video = ranked.filter { timeline.tracks[$0].kind == .video }
        let candidates = video.isEmpty ? ranked.filter { timeline.tracks[$0].kind.isVisual && timeline.tracks[$0].kind != .caption } : video
        // Highest media time; ties go to the lowest (bottom-most) track.
        return candidates.max { a, b in
            let ma = mediaSeconds(timeline.tracks[a]), mb = mediaSeconds(timeline.tracks[b])
            return ma != mb ? ma < mb : a > b
        }
    }

    static func isImage(_ item: Item) -> Bool { if case .image = item.content { true } else { false } }

    /// Item placed on whole frames: `[start, end)` with zero-length items dropped and overlaps (from rounding) trimmed.
    struct Placed {
        var item: Item
        var start: Int64
        var end: Int64
        var duration: Int64 { end - start }
    }

    static func place(_ items: [Item], grid: FrameGrid) -> [Placed] {
        var out: [Placed] = []
        var cursor = Int64.min
        for item in items.sorted(by: { $0.start < $1.start }) {
            let s = max(grid.frames(item.start), cursor), e = grid.frames(item.end)
            guard e > s else { continue }
            out.append(Placed(item: item, start: s, end: e))
            cursor = e
        }
        return out
    }

    /// Track gain + item gain, in dB, at an item-relative time.
    static func gainDB(_ item: Item, track: Track, at t: RationalTime) -> Double { item.gain.value(at: t) + track.gain }

    /// Encodes a Codable value to a JSON object tree (for embedding in OTIO metadata).
    static func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try JSONSerialization.jsonObject(with: enc.encode(value), options: [.fragmentsAllowed])
    }
}

/// Compact decimal: up to 4 fractional digits, no trailing zeros, no "-0".
func decimal(_ x: Double, digits: Int = 4) -> String {
    guard x.isFinite else { return "0" }
    var s = String(format: "%.\(digits)f", x)
    if s.contains(".") {
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
    }
    return s == "-0" ? "0" : s
}
