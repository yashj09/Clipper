import Foundation

/// Facts commands need beyond the timeline itself.
public struct EditContext: Sendable {
    /// Source durations, to keep media ranges inside their files.
    public var assetDurations: [AssetID: RationalTime]
    public var makeID: @Sendable () -> UUID

    public init(assetDurations: [AssetID: RationalTime] = [:], makeID: @escaping @Sendable () -> UUID = { UUID() }) {
        self.assetDurations = assetDurations; self.makeID = makeID
    }
}

public enum EditError: Error, Equatable, CustomStringConvertible {
    case itemNotFound(ItemID)
    case trackNotFound(TrackID)
    case trackLocked(TrackID)
    case itemLocked(ItemID)
    case overlap(TrackID)
    case invalidRange(String)
    case nothingToDo

    public var description: String {
        switch self {
        case .itemNotFound: "Item not found"
        case .trackNotFound: "Track not found"
        case .trackLocked: "Track is locked"
        case .itemLocked: "Item is locked"
        case .overlap: "Items would overlap on the track"
        case .invalidRange(let why): "Invalid range: \(why)"
        case .nothingToDo: "Nothing to do"
        }
    }
}

/// An undoable edit: a pure function from timeline to timeline.
public protocol EditCommand: Sendable {
    var name: String { get }
    /// Consecutive commands with the same non-nil key merge into one undo step (e.g. dragging a slider).
    var coalescingKey: String? { get }
    func apply(to timeline: Timeline, context: EditContext) throws -> Timeline
}

extension EditCommand { public var coalescingKey: String? { nil } }

/// Collision handling when placing an item.
public enum PlacementMode: Sendable { case reject, overwrite }

// MARK: - Helpers

extension Timeline {
    func requireUnlockedTrack(_ id: TrackID) throws -> Int {
        guard let ti = trackIndex(id) else { throw EditError.trackNotFound(id) }
        guard !tracks[ti].locked else { throw EditError.trackLocked(id) }
        return ti
    }

    /// Places `item` on track `ti`. In overwrite mode, whatever it covers is trimmed, split or removed.
    mutating func place(_ item: Item, onTrack ti: Int, mode: PlacementMode, context: EditContext) throws {
        let others = tracks[ti].items.filter { $0.id != item.id && $0.range.overlaps(item.range) }
        if !others.isEmpty {
            guard mode == .overwrite else { throw EditError.overlap(tracks[ti].id) }
            // Locked items are never cut into, as with blade and trim.
            if let locked = others.first(where: \.locked) { throw EditError.itemLocked(locked.id) }
            for o in others { try clear(item.range, onTrack: ti, item: o, context: context) }
        }
        tracks[ti].items.removeAll { $0.id == item.id }
        tracks[ti].items.append(item)
        tracks[ti].sortItems()
        if !others.isEmpty { removeEmptyCaptions() }
    }

    /// Removes the part of `item` covered by `range`.
    mutating func clear(_ range: TimeRange, onTrack ti: Int, item: Item, context: EditContext) throws {
        guard let ii = tracks[ti].index(of: item.id) else { return }
        if range.start <= item.start && range.end >= item.end {
            tracks[ti].items.remove(at: ii)
        } else if range.start > item.start && range.end < item.end {
            var tail = item.trimmedStart(to: range.end)
            tail.id = context.makeID()
            tracks[ti].items[ii] = item.trimmedEnd(to: range.start)
            tracks[ti].items.append(tail)
        } else if range.start <= item.start {
            tracks[ti].items[ii] = item.trimmedStart(to: range.end)
        } else {
            tracks[ti].items[ii] = item.trimmedEnd(to: range.start)
        }
    }
}

extension RationalTime {
    /// Timeline duration → source duration at `speed`. Frame-aligned times have a small timescale (e.g. 30), where
    /// `* speed` would round by up to half a frame; working at ≥ the default scale keeps the error under 10 µs.
    func timesSpeed(_ speed: Double) -> RationalTime {
        speed == 1 ? self : rescaled(to: Swift.max(scale, RationalTime.defaultScale)) * speed
    }
}

extension Item {
    /// Moves the in-point to timeline time `t`, keeping the media under the playhead in sync.
    public func trimmedStart(to t: RationalTime) -> Item {
        var c = self
        let delta = t - range.start
        c.range = TimeRange(start: t, end: range.end)
        if case .media(var m) = content {
            m.source = TimeRange(start: m.source.start + delta.timesSpeed(m.speed), duration: c.range.duration.timesSpeed(m.speed))
            c.content = .media(m)
        }
        c.shiftKeyframes(by: -delta)
        c.fitCaptionWords()
        return c
    }

    /// Moves the out-point to timeline time `t`.
    public func trimmedEnd(to t: RationalTime) -> Item {
        var c = self
        c.range = TimeRange(start: range.start, end: t)
        if case .media(var m) = content {
            m.source.duration = c.range.duration.timesSpeed(m.speed)
            c.content = .media(m)
        }
        c.fitCaptionWords()
        return c
    }

    /// A caption page shows all of its words at once, so after a split or trim it keeps only the words mostly inside it
    /// (by their midpoint), clamped to its range — otherwise both halves of a split page would show the whole text.
    mutating func fitCaptionWords() {
        guard case .caption(var cap) = content else { return }
        let d = range.duration
        cap.words = cap.words.compactMap { w in
            let mid = (w.start + w.end) * 0.5
            guard mid >= .zero, mid < d else { return nil }
            var c = w
            c.start = .max(w.start, .zero)
            c.end = .min(w.end, d)
            return c
        }
        content = .caption(cap)
    }

    /// Keyframes are item-relative; trimming the head must move them to stay pinned to the same media.
    mutating func shiftKeyframes(by d: RationalTime) {
        func shift<V>(_ p: Param<V>) -> Param<V> {
            guard case .keyframes(let k) = p else { return p }
            return .keyframes(k.map { Keyframe($0.time + d, $0.value, $0.interpolation) })
        }
        opacity = shift(opacity); gain = shift(gain)
        transform.position = shift(transform.position); transform.scale = shift(transform.scale)
        transform.rotation = shift(transform.rotation); transform.zoom = shift(transform.zoom)
        transform.focus = shift(transform.focus)
        if case .caption(var cap) = content {
            cap.words = cap.words.map { var w = $0; w.start += d; w.end += d; return w }
            content = .caption(cap)
        }
    }
}

// MARK: - Commands

public struct InsertItem: EditCommand {
    public var item: Item
    public var track: TrackID
    public var mode: PlacementMode
    public init(_ item: Item, on track: TrackID, mode: PlacementMode = .reject) { self.item = item; self.track = track; self.mode = mode }
    public var name: String { "Insert \(item.name.isEmpty ? "Item" : item.name)" }

    public func apply(to timeline: Timeline, context: EditContext) throws -> Timeline {
        guard !item.range.isEmpty else { throw EditError.invalidRange("empty item") }
        var t = timeline
        let ti = try t.requireUnlockedTrack(track)
        try t.place(item, onTrack: ti, mode: mode, context: context)
        return t
    }
}

public struct DeleteItems: EditCommand {
    public var ids: Set<ItemID>
    /// Close the gaps left behind on each affected track.
    public var ripple: Bool
    public init(_ ids: Set<ItemID>, ripple: Bool = false) { self.ids = ids; self.ripple = ripple }
    public var name: String { ripple ? "Ripple Delete" : "Delete" }

    public func apply(to timeline: Timeline, context: EditContext) throws -> Timeline {
        var t = timeline
        var found = false
        for ti in t.tracks.indices {
            let removed = t.tracks[ti].items.filter { ids.contains($0.id) }
            guard !removed.isEmpty else { continue }
            guard !t.tracks[ti].locked else { throw EditError.trackLocked(t.tracks[ti].id) }
            found = true
            t.tracks[ti].items.removeAll { ids.contains($0.id) }
            if ripple {
                // Shift later items left by the total removed duration before them.
                t.tracks[ti].items = t.tracks[ti].items.map { item in
                    let gap = removed.filter { $0.end <= item.start }.reduce(RationalTime.zero) { $0 + $1.range.duration }
                    var c = item; c.range = item.range.offset(by: -gap); return c
                }
            }
        }
        guard found else { throw EditError.nothingToDo }
        return t
    }
}

public struct MoveItem: EditCommand {
    public var id: ItemID
    public var toTrack: TrackID
    public var toStart: RationalTime
    public var mode: PlacementMode
    public init(_ id: ItemID, to track: TrackID, at start: RationalTime, mode: PlacementMode = .reject) {
        self.id = id; self.toTrack = track; self.toStart = start; self.mode = mode
    }
    public var name: String { "Move" }

    public func apply(to timeline: Timeline, context: EditContext) throws -> Timeline {
        guard toStart >= .zero else { throw EditError.invalidRange("before timeline start") }
        var t = timeline
        guard let loc = t.locate(id) else { throw EditError.itemNotFound(id) }
        guard !t.tracks[loc.track].locked else { throw EditError.trackLocked(t.tracks[loc.track].id) }
        var item = t.tracks[loc.track].items.remove(at: loc.item)
        item.range.start = toStart
        let ti = try t.requireUnlockedTrack(toTrack)
        try t.place(item, onTrack: ti, mode: mode, context: context)
        return t
    }
}

public enum TrimEdge: Sendable { case start, end }

public struct TrimItem: EditCommand {
    public var id: ItemID
    public var edge: TrimEdge
    public var to: RationalTime
    /// Ripple: shift following items on the same track so no gap/overlap is created.
    public var ripple: Bool
    public init(_ id: ItemID, edge: TrimEdge, to: RationalTime, ripple: Bool = false) {
        self.id = id; self.edge = edge; self.to = to; self.ripple = ripple
    }
    public var name: String { ripple ? "Ripple Trim" : "Trim" }
    public var coalescingKey: String? { "trim-\(id)-\(edge)" }

    public func apply(to timeline: Timeline, context: EditContext) throws -> Timeline {
        var t = timeline
        guard let loc = t.locate(id) else { throw EditError.itemNotFound(id) }
        let ti = try t.requireUnlockedTrack(t.tracks[loc.track].id)
        let item = t.tracks[ti].items[loc.item]
        guard !item.locked else { throw EditError.itemLocked(id) }
        let minDur = t.canvas.frameRate.frameDuration
        var new: Item
        switch edge {
        case .start:
            guard to <= item.end - minDur, to >= .zero else { throw EditError.invalidRange("start past end") }
            new = item.trimmedStart(to: to)
        case .end:
            guard to >= item.start + minDur else { throw EditError.invalidRange("end before start") }
            new = item.trimmedEnd(to: to)
        }
        if case .media(let m) = new.content {
            if m.source.start < .zero { throw EditError.invalidRange("before media start") }
            if let d = context.assetDurations[m.asset], m.source.end > d { throw EditError.invalidRange("past media end") }
        }
        let delta = edge == .end ? new.end - item.end : new.start - item.start
        t.tracks[ti].items[loc.item] = new
        if ripple {
            // Ripple keeps the item's later neighbours glued to its out-point; a head trim keeps the out-point
            // fixed in place, so ripple moves the item itself instead.
            if edge == .end {
                for i in t.tracks[ti].items.indices where t.tracks[ti].items[i].start >= item.end {
                    t.tracks[ti].items[i].range = t.tracks[ti].items[i].range.offset(by: delta)
                }
            } else {
                for i in t.tracks[ti].items.indices where t.tracks[ti].items[i].start >= item.end {
                    t.tracks[ti].items[i].range = t.tracks[ti].items[i].range.offset(by: -delta)
                }
                var moved = t.tracks[ti].items[loc.item]
                moved.range = moved.range.offset(by: -delta)
                t.tracks[ti].items[loc.item] = moved
            }
        }
        let others = t.tracks[ti].items.enumerated().filter { $0.offset != loc.item }.map(\.element)
        let current = t.tracks[ti].items[loc.item]
        if others.contains(where: { $0.range.overlaps(current.range) }) { throw EditError.overlap(t.tracks[ti].id) }
        if t.tracks[ti].items.contains(where: { $0.start < .zero }) { throw EditError.invalidRange("before timeline start") }
        t.tracks[ti].sortItems()
        return t
    }
}

/// Splits every item under the playhead (optionally only on some tracks).
public struct Blade: EditCommand {
    public var at: RationalTime
    public var tracks: Set<TrackID>?
    public init(at: RationalTime, tracks: Set<TrackID>? = nil) { self.at = at; self.tracks = tracks }
    public var name: String { "Blade" }

    public func apply(to timeline: Timeline, context: EditContext) throws -> Timeline {
        var t = timeline
        var did = false
        for ti in t.tracks.indices where (tracks?.contains(t.tracks[ti].id) ?? true) && !t.tracks[ti].locked {
            guard let ii = t.tracks[ti].items.firstIndex(where: { $0.start < at && at < $0.end }) else { continue }
            let item = t.tracks[ti].items[ii]
            guard !item.locked else { continue }
            var tail = item.trimmedStart(to: at)
            tail.id = context.makeID()
            t.tracks[ti].items[ii] = item.trimmedEnd(to: at)
            t.tracks[ti].items.insert(tail, at: ii + 1)
            did = true
        }
        guard did else { throw EditError.nothingToDo }
        t.removeEmptyCaptions()
        return t
    }
}

/// Arbitrary property change on one item (opacity, gain, transform, text…), validated afterwards.
public struct ModifyItem: EditCommand {
    public var id: ItemID
    public var name: String
    public var coalescingKey: String?
    public var change: @Sendable (inout Item) -> Void

    public init(_ id: ItemID, name: String, coalescingKey: String? = nil, _ change: @escaping @Sendable (inout Item) -> Void) {
        self.id = id; self.name = name; self.coalescingKey = coalescingKey; self.change = change
    }

    public func apply(to timeline: Timeline, context: EditContext) throws -> Timeline {
        var t = timeline
        guard let loc = t.locate(id) else { throw EditError.itemNotFound(id) }
        guard !t.tracks[loc.track].locked else { throw EditError.trackLocked(t.tracks[loc.track].id) }
        var item = t.tracks[loc.track].items[loc.item]
        let before = item.range
        change(&item)
        t.tracks[loc.track].items[loc.item] = item
        if item.range != before {
            let others = t.tracks[loc.track].items.filter { $0.id != id }
            if others.contains(where: { $0.range.overlaps(item.range) }) { throw EditError.overlap(t.tracks[loc.track].id) }
            t.tracks[loc.track].sortItems()
        }
        return t
    }
}

public struct AddTrack: EditCommand {
    public var track: Track
    public var index: Int?
    public init(_ track: Track, at index: Int? = nil) { self.track = track; self.index = index }
    public var name: String { "Add Track" }
    public func apply(to timeline: Timeline, context: EditContext) throws -> Timeline {
        var t = timeline
        t.tracks.insert(track, at: min(index ?? t.tracks.count, t.tracks.count))
        return t
    }
}

public struct ModifyTrack: EditCommand {
    public var id: TrackID
    public var name: String
    public var change: @Sendable (inout Track) -> Void
    public init(_ id: TrackID, name: String, _ change: @escaping @Sendable (inout Track) -> Void) {
        self.id = id; self.name = name; self.change = change
    }
    public func apply(to timeline: Timeline, context: EditContext) throws -> Timeline {
        var t = timeline
        guard let ti = t.trackIndex(id) else { throw EditError.trackNotFound(id) }
        change(&t.tracks[ti])
        t.tracks[ti].sortItems()
        return t
    }
}

/// Replaces the whole timeline in one undo step (applying an automatic draft).
public struct ReplaceTimeline: EditCommand {
    public var timeline: Timeline
    public var name: String
    public init(_ timeline: Timeline, name: String = "Apply Draft") { self.timeline = timeline; self.name = name }
    public func apply(to _: Timeline, context: EditContext) throws -> Timeline { timeline }
}

// MARK: - History

/// Snapshot-based undo/redo: each step stores the timeline before the command. Value semantics make the
/// snapshots cheap (unchanged tracks share storage) and undo can never drift from redo.
public struct EditHistory: Sendable {
    public struct Step: Sendable { public var name: String; public var before: Timeline; var key: String? }
    public private(set) var undoStack: [Step] = []
    public private(set) var redoStack: [Step] = []
    public var limit = 200

    public init() {}

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoName: String? { undoStack.last?.name }
    public var redoName: String? { redoStack.last?.name }

    @discardableResult
    public mutating func perform(_ command: any EditCommand, on timeline: inout Timeline, context: EditContext) throws -> Timeline {
        let result = try command.apply(to: timeline, context: context)
        if let key = command.coalescingKey, let last = undoStack.last, last.key == key {
            // Merge into the previous step: keep its "before" snapshot.
        } else {
            undoStack.append(Step(name: command.name, before: timeline, key: command.coalescingKey))
            if undoStack.count > limit { undoStack.removeFirst() }
        }
        redoStack.removeAll()
        timeline = result
        return result
    }

    public mutating func undo(_ timeline: inout Timeline) {
        guard let step = undoStack.popLast() else { return }
        redoStack.append(Step(name: step.name, before: timeline, key: nil))
        timeline = step.before
    }

    public mutating func redo(_ timeline: inout Timeline) {
        guard let step = redoStack.popLast() else { return }
        undoStack.append(Step(name: step.name, before: timeline, key: nil))
        timeline = step.before
    }

    /// Ends coalescing (e.g. on mouse-up), so the next change starts a new undo step.
    public mutating func breakCoalescing() {
        if var last = undoStack.popLast() { last.key = nil; undoStack.append(last) }
    }
}
