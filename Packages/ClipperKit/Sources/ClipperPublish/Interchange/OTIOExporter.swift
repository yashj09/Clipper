import ClipperCore
import Foundation

/// Exports a Clipper timeline as OpenTimelineIO JSON (`.otio`), readable by `opentimelineio` ≥ 0.15, DaVinci Resolve,
/// Premiere (via the OTIO plug-in), Avid/Nuke/RV adapters.
///
/// ## Mapping
/// - `Timeline.1` → `Stack.1` with one `Track.1` per Clipper track, bottom to top (OTIO stacks composite later children
///   over earlier ones, like Clipper). Visual kinds are `"Video"` tracks, audio/music `"Audio"`.
/// - A `.video` track whose clips carry sound also gets a mirrored `"Audio"` track (`linkedAudioTracks`), because
///   OTIO clips on a video track don't bring their audio into most NLEs.
/// - Media → `Clip.2` + `ExternalReference.1` (`target_url` = the original file, `available_range` = the whole file).
///   Text, captions and solids → `Clip.2` + `GeneratorReference.1` (`clipper.text`, `clipper.caption`, `SolidColor`);
///   holes → `Gap.1`.
/// - **Time**: `RationalTime.1` with `rate` = the timeline frame rate (`30000/1001` → 29.97002997…) and `value` in
///   frames. Timeline positions are whole frames (edges rounded once, so tracks stay contiguous); source starts keep
///   their exact sub-frame value as a fractional frame count.
/// - **Speed**: `LinearTimeWarp.1(time_scalar = speed)`; per OTIO convention the clip's `source_range.duration` is
///   its duration on the track and `start_time` is the source in-point.
/// - Timeline markers → `Marker.2` on the top-level stack, one frame long, colour `ORANGE`.
/// - **Everything else** (transform, opacity, gain keyframes/ducking, fades, caption words, styles, track gain…)
///   travels losslessly under `metadata["clipper"]`: `item` is the encoded `Item`, `track` the track without items,
///   `timeline` the timeline without tracks. Other tools ignore it; a Clipper importer can rebuild the timeline.
public struct OTIOExporter: TimelineInterchangeExporter {
    public static let fileExtension = "otio"

    public var linkedAudioTracks: Bool

    public init(linkedAudioTracks: Bool = true) { self.linkedAudioTracks = linkedAudioTracks }

    public func export(_ timeline: Timeline, assets: [AssetID: MediaAsset]) throws -> Data {
        let grid = FrameGrid(timeline.canvas.frameRate)
        guard grid.isValid else { throw InterchangeError.invalidFrameRate(timeline.canvas.frameRate) }
        _ = try InterchangeModel.usedAssets(timeline, assets)
        let writer = Writer(timeline: timeline, assets: assets, grid: grid)

        var tracks: [Any] = []
        for track in timeline.tracks {
            let placed = InterchangeModel.place(track.items, grid: grid)
            tracks.append(try writer.track(track, placed: placed, audioMirror: false))
            if linkedAudioTracks, track.kind == .video, placed.contains(where: { writer.playsAudio($0.item, track: track) }) {
                tracks.append(try writer.track(track, placed: placed, audioMirror: true))
            }
        }

        var withoutTracks = timeline
        withoutTracks.tracks = []
        var timelineMeta = try InterchangeModel.jsonObject(withoutTracks) as? [String: Any] ?? [:]
        timelineMeta["tracks"] = nil
        let root: [String: Any] = [
            "OTIO_SCHEMA": "Timeline.1",
            "name": timeline.name,
            "global_start_time": NSNull(),
            "metadata": ["clipper": ["version": 1, "timeline": timelineMeta]],
            "tracks": [
                "OTIO_SCHEMA": "Stack.1",
                "name": "tracks",
                "children": tracks,
                "source_range": NSNull(),
                "effects": [Any](),
                "markers": timeline.markers.map(writer.marker),
                "enabled": true,
                "metadata": [String: Any](),
            ] as [String: Any],
        ]
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}

private struct Writer {
    let timeline: Timeline
    let assets: [AssetID: MediaAsset]
    let grid: FrameGrid

    var rate: Double { grid.fps }

    func rt(_ frames: Double) -> [String: Any] { ["OTIO_SCHEMA": "RationalTime.1", "rate": rate, "value": frames] }

    func range(_ start: Double, _ duration: Double) -> [String: Any] {
        ["OTIO_SCHEMA": "TimeRange.1", "start_time": rt(start), "duration": rt(duration)]
    }

    func playsAudio(_ item: Item, track: Track) -> Bool {
        guard let ref = item.content.mediaRef, let asset = assets[ref.asset] else { return false }
        return ref.useAudio && asset.info.hasAudio && asset.info.kind != .image
    }

    func track(_ track: Track, placed: [InterchangeModel.Placed], audioMirror: Bool) throws -> [String: Any] {
        var children: [Any] = []
        var cursor: Int64 = 0
        for p in placed {
            if p.start > cursor { children.append(gap(p.start - cursor)) }
            if audioMirror && !playsAudio(p.item, track: track) {
                children.append(gap(p.duration))
            } else {
                children.append(try clip(p, track: track, audioMirror: audioMirror))
            }
            cursor = p.end
        }
        var meta = try InterchangeModel.jsonObject(Track(
            id: track.id, kind: track.kind, name: track.name, items: [], muted: track.muted, hidden: track.hidden,
            locked: track.locked, gain: track.gain, language: track.language)) as? [String: Any] ?? [:]
        meta["items"] = nil
        var clipper: [String: Any] = ["track": meta]
        if audioMirror { clipper["audioOf"] = track.id.uuidString }

        let audio = audioMirror || !track.kind.isVisual
        return [
            "OTIO_SCHEMA": "Track.1",
            "name": audioMirror ? "\(track.name) Audio" : track.name,
            "kind": audio ? "Audio" : "Video",
            "children": children,
            "enabled": audio ? !track.muted : !track.hidden,
            "source_range": NSNull(),
            "effects": [Any](),
            "markers": [Any](),
            "metadata": ["clipper": clipper],
        ]
    }

    func marker(_ marker: Marker) -> [String: Any] {
        ["OTIO_SCHEMA": "Marker.2", "name": marker.name, "color": "ORANGE",
         "marked_range": range(Double(grid.frames(marker.time)), 1),
         "metadata": ["clipper": ["id": marker.id.uuidString]]]
    }

    func gap(_ frames: Int64) -> [String: Any] {
        ["OTIO_SCHEMA": "Gap.1", "name": "", "source_range": range(0, Double(frames)), "effects": [Any](),
         "markers": [Any](), "enabled": true, "metadata": [String: Any]()]
    }

    func clip(_ p: InterchangeModel.Placed, track: Track, audioMirror: Bool) throws -> [String: Any] {
        let item = p.item
        var name = item.name
        var sourceStart = 0.0
        var effects: [Any] = []
        let reference: [String: Any]
        switch item.content {
        case .media(let ref):
            let asset = assets[ref.asset]!
            if name.isEmpty { name = asset.name }
            sourceStart = grid.frameValue(ref.source.start)
            reference = external(asset)
            if abs(ref.speed - 1) > 1e-9 {
                effects.append(["OTIO_SCHEMA": "LinearTimeWarp.1", "name": "", "effect_name": "LinearTimeWarp",
                                "time_scalar": ref.speed, "enabled": true, "metadata": [String: Any]()])
            }
        case .image(let id):
            let asset = assets[id]!
            if name.isEmpty { name = asset.name }
            reference = external(asset)
        case .text(let t):
            if name.isEmpty { name = t.text }
            reference = generator("clipper.text", ["text": t.text, "style": t.style])
        case .caption(let c):
            let text = CaptionLanguage.join(c.words.map(\.text), language: track.language)
            if name.isEmpty { name = text }
            reference = generator("clipper.caption", ["text": text, "style": c.style, "language": track.language ?? ""])
        case .solid(let color):
            if name.isEmpty { name = "Solid" }
            reference = generator("SolidColor", ["color": color.hex])
        }
        return [
            "OTIO_SCHEMA": "Clip.2",
            "name": name,
            "source_range": range(sourceStart, Double(p.duration)),
            "media_references": ["DEFAULT_MEDIA": reference],
            "active_media_reference_key": "DEFAULT_MEDIA",
            "effects": effects,
            "markers": [Any](),
            "enabled": true,
            "metadata": ["clipper": ["item": try InterchangeModel.jsonObject(item)]],
        ]
    }

    func external(_ asset: MediaAsset) -> [String: Any] {
        [
            "OTIO_SCHEMA": "ExternalReference.1",
            "name": asset.name,
            "target_url": asset.url.absoluteString,
            "available_range": asset.info.kind == .image ? NSNull() : range(0, grid.frameValue(asset.info.duration)),
            "available_image_bounds": NSNull(),
            "metadata": ["clipper": ["asset": asset.id.uuidString, "key": asset.key.rawValue]],
        ]
    }

    func generator(_ kind: String, _ parameters: [String: Any]) -> [String: Any] {
        [
            "OTIO_SCHEMA": "GeneratorReference.1",
            "name": "",
            "generator_kind": kind,
            "parameters": parameters,
            "available_range": NSNull(),
            "available_image_bounds": NSNull(),
            "metadata": [String: Any](),
        ]
    }
}
