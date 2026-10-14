import AppKit
import ClipperAutomation
import ClipperCore
import Foundation

/// Zoom changes the timeline view should make (it owns the zoom level; requests carry a UUID so repeats register).
enum ZoomRequest: Equatable { case fit(UUID), zoomIn(UUID), zoomOut(UUID) }

/// Something in the editor's browser that can go on the timeline.
enum BrowserItem: Hashable {
    case asset(AssetID)
    case music(String)
    case title(String)

    /// Drag payload. Plain text, so the AppKit timeline can read it from the pasteboard.
    var payload: String {
        switch self {
        case .asset(let id): "clipper-asset:\(id.uuidString)"
        case .music(let id): "clipper-music:\(id)"
        case .title(let style): "clipper-title:\(style)"
        }
    }

    /// Parses a payload; a bare UUID is a media card dragged from the library grid.
    init?(payload: String) {
        if let id = UUID(uuidString: payload) { self = .asset(id); return }
        let (kind, value) = (payload.prefix { $0 != ":" }, payload.drop { $0 != ":" }.dropFirst())
        guard !value.isEmpty else { return nil }
        switch kind {
        case "clipper-asset": guard let id = UUID(uuidString: String(value)) else { return nil }; self = .asset(id)
        case "clipper-music": self = .music(String(value))
        case "clipper-title": self = .title(String(value))
        default: return nil
        }
    }
}

/// How a browser clip goes onto the timeline (Final Cut's Q / W / E / D).
enum AddMode {
    /// On a free track at the playhead, disturbing nothing.
    case connect
    /// Into the main track at the playhead, pushing everything after it later on every track.
    case insert
    /// At the end of the main track.
    case append
    /// Over whatever is on the main track at the playhead.
    case overwrite
}

/// An item ready to add, with the tracks it may go on.
struct AddableItem {
    var item: Item
    /// Track kinds for "connect", best first.
    var kinds: [TrackKind]
    /// The kind of the track insert / append / overwrite edit into.
    var primary: TrackKind
    /// Commands the item depends on (adding a missing text style).
    var prerequisites: [any EditCommand] = []
}

/// A copied item and where it came from.
struct ClipboardEntry {
    var item: Item
    var track: TrackID
    var kinds: [TrackKind]
}

extension TrackKind {
    /// Kinds an item from a track of this kind may move to, best first.
    var compatibleKinds: [TrackKind] {
        switch self {
        case .video: [.video, .overlay]
        case .overlay: [.overlay, .video]
        case .title: [.title, .overlay]
        case .caption: [.caption]
        case .audio: [.audio, .music]
        case .music: [.music, .audio]
        }
    }
}

@MainActor
extension EditorModel {
    /// Shared by every editor in this session, so clips can be copied between projects.
    static var clipboard: [ClipboardEntry] = []

    private var frame: RationalTime { timeline.canvas.frameRate.frameDuration }
    private var ripple: Bool { settings.editing.rippleByDefault }

    /// The In–Out range: from In (or the start) to Out (or the end).
    var markedRange: TimeRange? {
        guard inPoint != nil || outPoint != nil else { return nil }
        let a = inPoint ?? .zero, b = outPoint ?? timeline.duration
        return a < b ? TimeRange(start: a, end: b) : nil
    }

    /// Runs an editing action. Actions that need the app (browser edits, settings toggles, file commands) are handled by
    /// `AppModel.perform` and are no-ops here.
    func run(_ action: EditorAction) {
        switch action {
        case .playPause: togglePlay()
        case .shuttleBackward: shuttle(forward: false)
        case .shuttleForward: shuttle(forward: true)
        case .pause: player.pause()
        case .previousFrame: player.pause(); step(frames: -1)
        case .nextFrame: player.pause(); step(frames: 1)
        case .back10Frames: player.pause(); step(frames: -10)
        case .forward10Frames: player.pause(); step(frames: 10)
        case .previousEdit: player.pause(); seek(to: editPoints.last { $0 < playhead } ?? .zero)
        case .nextEdit: player.pause(); seek(to: editPoints.first { $0 > playhead } ?? timeline.duration)
        case .goToStart: seek(to: .zero)
        case .goToEnd: seek(to: timeline.duration)
        case .setIn:
            inPoint = playhead
            if let o = outPoint, o <= playhead { outPoint = nil }
        case .setOut:
            outPoint = playhead
            if let i = inPoint, i >= playhead { inPoint = nil }
        case .clearInOut: inPoint = nil; outPoint = nil
        case .selectClipRange:
            guard let item = selectedItems.count == 1 ? selectedItems[0] : clipAtPlayhead() else { return NSSound.beep() }
            inPoint = item.start; outPoint = item.end
        case .blade: bladeAtPlayhead()
        case .bladeAllTracks: perform(Blade(at: playhead))
        case .delete: deleteSelectionOrRange(ripple: ripple)
        case .rippleDelete: deleteSelectionOrRange(ripple: true)
        case .deleteLeavingGap: deleteSelectionOrRange(ripple: false)
        case .trimStartToPlayhead: trimToPlayhead(.start)
        case .trimEndToPlayhead: trimToPlayhead(.end)
        case .nudgeLeft: nudge(by: -frame)
        case .nudgeRight: nudge(by: frame)
        case .selectClipAtPlayhead:
            if let item = clipAtPlayhead() { selection = [item.id] } else { NSSound.beep() }
        case .selectAll: selection = Set(timeline.allItems.map(\.id))
        case .deselectAll: selection = []
        case .cut:
            guard copySelection() else { return }
            deleteSelection(ripple: ripple)
        case .copy: _ = copySelection()
        case .paste: paste(Self.clipboard, at: playhead, name: "Paste")
        case .duplicate: duplicateSelection()
        case .toggleLock: toggleLock()
        case .undo: undo()
        case .redo: redo()
        case .addText: addText()
        case .zoomIn: zoomRequest = .zoomIn(UUID())
        case .zoomOut: zoomRequest = .zoomOut(UUID())
        case .zoomToFit: zoomRequest = .fit(UUID())
        case .connectToTimeline, .insertAtPlayhead, .appendToStoryline, .overwriteAtPlayhead,
             .toggleSnapping, .toggleRipple, .importMedia, .newDraft, .export: break
        }
    }

    // MARK: Navigation

    /// Cut points on every track except captions (each caption page is its own item, so they'd make stepping useless).
    var editPoints: [RationalTime] {
        var points = Set<RationalTime>([.zero, timeline.duration])
        for track in timeline.tracks where track.kind != .caption {
            for item in track.items { points.insert(item.start); points.insert(item.end) }
        }
        return points.sorted()
    }

    /// The clip under the playhead, preferring the main video, then overlays, titles, audio and music.
    func clipAtPlayhead() -> Item? {
        let order: [TrackKind] = [.video, .overlay, .title, .audio, .music]
        for kind in order {
            for track in timeline.tracks where track.kind == kind && !track.hidden {
                if let item = track.items.first(where: { $0.range.contains(playhead) }) { return item }
            }
        }
        return nil
    }

    // MARK: Editing

    /// Deletes the selection; with nothing selected, removes the In–Out range from every unlocked track.
    func deleteSelectionOrRange(ripple: Bool) {
        if !selection.isEmpty { return deleteSelection(ripple: ripple) }
        guard let range = markedRange else { return NSSound.beep() }
        perform(RemoveRange(range, ripple: ripple))
        guard lastError == nil else { return }
        inPoint = nil; outPoint = nil
        seek(to: range.start)
    }

    /// Trims the selected clips that the playhead crosses — or the clip under it — so they start or end at the playhead.
    /// With ripple on, a start trim pulls the rest of the track left and the playhead follows the cut.
    private func trimToPlayhead(_ edge: TrimEdge) {
        let p = playhead
        var targets = selectedItems.filter { $0.start < p && p < $0.end }
        if targets.isEmpty, let item = clipAtPlayhead(), item.start < p { targets = [item] }
        guard !targets.isEmpty else { return NSSound.beep() }
        lastError = nil
        perform(Batch(targets.map { TrimItem($0.id, edge: edge, to: p, ripple: ripple) },
                      name: edge == .start ? "Trim Start" : "Trim End"))
        if edge == .start, ripple, lastError == nil, let first = targets.map(\.start).min() { seek(to: first) }
    }

    private func nudge(by delta: RationalTime) {
        guard !selection.isEmpty else { return NSSound.beep() }
        perform(NudgeItems(selection, by: delta))
    }

    // MARK: Clipboard

    @discardableResult
    func copySelection() -> Bool {
        let entries = selectedItems.compactMap { item -> ClipboardEntry? in
            guard let loc = timeline.locate(item.id) else { return nil }
            let track = timeline.tracks[loc.track]
            return ClipboardEntry(item: item, track: track.id, kinds: track.kind.compatibleKinds)
        }
        guard !entries.isEmpty else { NSSound.beep(); return false }
        Self.clipboard = entries.sorted { $0.item.start < $1.item.start }
        return true
    }

    /// Places copies at `time` (keeping their spacing), each on its original track when free; never overwrites.
    func paste(_ entries: [ClipboardEntry], at time: RationalTime, name: String) {
        guard let base = entries.map(\.item.start).min() else { return NSSound.beep() }
        // Media from another library can't play here.
        let usable = entries.filter { $0.item.content.mediaRef.map { assets[$0.asset] != nil } ?? true }
        guard !usable.isEmpty else { return NSSound.beep() }
        var placed: [ItemID] = []
        let placements = usable.map { e -> PlaceItems.Placement in
            var item = e.item
            item.id = UUID()
            item.range.start = time + (e.item.start - base)
            item.origin = .user
            item.locked = false
            placed.append(item.id)
            return .init(item, track: e.track, kinds: e.kinds)
        }
        lastError = nil
        perform(PlaceItems(placements, name: name))
        if lastError == nil { selection = Set(placed) }
    }

    /// Copies of the selection right after it.
    private func duplicateSelection() {
        let items = selectedItems
        guard let end = items.map(\.end).max() else { return NSSound.beep() }
        let entries = items.compactMap { item -> ClipboardEntry? in
            guard let loc = timeline.locate(item.id) else { return nil }
            let track = timeline.tracks[loc.track]
            return ClipboardEntry(item: item, track: track.id, kinds: track.kind.compatibleKinds)
        }
        paste(entries, at: end, name: "Duplicate")
    }

    // MARK: Adding

    /// The title style a new text uses: the draft's bold title style when the timeline has it.
    var defaultTitleStyle: String {
        ["title-bold", "title-clean"].first { timeline.styles[$0] != nil }
            ?? timeline.styles.keys.sorted().first { $0.contains("title") }
            ?? "title-bold"
    }

    /// A text item at `time` in `style`, placed where the style puts titles. Adds the style if the timeline lacks it.
    func textItem(style: String? = nil, at time: RationalTime) -> AddableItem {
        let key = style ?? defaultTitleStyle
        var prerequisites: [any EditCommand] = []
        let value = timeline.styles[key] ?? BuiltIns.styles[key] ?? BuiltIns.styles["title-bold"]!
        if timeline.styles[key] == nil { prerequisites.append(SetStyle(key, value)) }
        var item = Item(name: "Text", range: TimeRange(start: time, duration: RationalTime(seconds: 3).roundedToFrame(timeline.canvas.frameRate)),
                        content: .text(TextContent(text: "Your text", style: key)))
        item.transform.position = .constant(value.position)
        return AddableItem(item: item, kinds: [.title, .overlay], primary: .title, prerequisites: prerequisites)
    }

    /// A clip using the whole of `asset` (stills last 4 s), starting at `time`.
    func clipItem(_ asset: MediaAsset, at time: RationalTime) -> AddableItem? {
        let rate = timeline.canvas.frameRate
        switch asset.info.kind {
        case .image:
            let item = Item(name: asset.name, range: TimeRange(start: time, duration: RationalTime(seconds: 4).roundedToFrame(rate)),
                            content: .image(asset.id))
            return AddableItem(item: item, kinds: [.overlay, .video], primary: .video)
        case .video, .audio:
            let d = asset.info.duration.floorToFrame(rate)
            guard d > .zero else { return nil }
            let item = Item(name: asset.name, range: TimeRange(start: time, duration: d),
                            content: .media(MediaRef(asset: asset.id, source: TimeRange(start: .zero, duration: d), useAudio: asset.info.hasAudio)))
            if asset.info.kind == .video { return AddableItem(item: item, kinds: [.overlay, .video], primary: .video) }
            let music = asset.tags.contains("music")
            return AddableItem(item: item, kinds: music ? [.music, .audio] : [.audio, .music], primary: music ? .music : .audio)
        }
    }

    /// Adds the text at the playhead and selects it so the inspector can edit it.
    func addText(style: String? = nil) {
        add(textItem(style: style, at: playhead), mode: .connect)
    }

    /// Adds a browser clip with a Q / W / E / D edit at the playhead (or `track`, for drops onto a track).
    /// Insert, append and overwrite go to the main track of the item's kind; without one, the item is connected.
    func add(_ addable: AddableItem, mode: AddMode, track: TrackID? = nil) {
        var item = addable.item
        let target = track.flatMap { id in timeline.tracks.first { $0.id == id && addable.kinds.contains($0.kind) } }
            ?? timeline.tracks.first { $0.kind == addable.primary && !$0.locked }
        let edit: any EditCommand
        switch (mode, target) {
        case (.connect, _), (_, nil):
            edit = PlaceItems([.init(item, track: track, kinds: addable.kinds)], name: "Add \(item.name)")
        case (.append, let t?):
            item.range.start = t.end
            edit = InsertItem(item, on: t.id)
        case (.insert, let t?):
            edit = InsertEdit(item, on: t.id)
        case (.overwrite, let t?):
            edit = InsertItem(item, on: t.id, mode: .overwrite)
        }
        lastError = nil
        perform(addable.prerequisites.isEmpty ? edit : Batch(addable.prerequisites + [edit], name: edit.name))
        if lastError == nil, timeline.item(item.id) != nil { selection = [item.id] }
    }

    // MARK: Speed

    func setSpeed(_ id: ItemID, _ speed: Double) {
        perform(SetSpeed(id, speed: speed, ripple: ripple))
    }
}
