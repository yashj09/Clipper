import Foundation

// Edits used by the manual editor beyond the basics in Commands.swift: adding without disturbing ("connect"),
// insert edits that keep every track in sync, removing a marked range, nudging and speed changes.

extension Timeline {
    /// Where a new track of `kind` goes so the stacking stays sensible: footage under titles, titles under captions.
    func insertionIndex(forNew kind: TrackKind) -> Int {
        let above: Set<TrackKind> = switch kind {
        case .video, .overlay: [.title, .caption]
        case .title: [.caption]
        case .caption, .audio, .music: []
        }
        return tracks.firstIndex { above.contains($0.kind) } ?? tracks.count
    }

    /// Adds an empty track of `kind`, named "Overlay 2" etc. when one exists already; returns its index.
    mutating func addTrack(_ kind: TrackKind, context: EditContext) -> Int {
        let count = tracks.filter { $0.kind == kind }.count
        let name = kind.rawValue.capitalized + (count > 0 ? " \(count + 1)" : "")
        let i = insertionIndex(forNew: kind)
        tracks.insert(Track(id: context.makeID(), kind: kind, name: name), at: i)
        return i
    }
}

extension Item {
    /// Stretches item-relative keyframes by `factor` (a speed change makes the item longer or shorter).
    mutating func scaleKeyframes(by factor: Double) {
        func scale<V>(_ p: Param<V>) -> Param<V> {
            guard case .keyframes(let k) = p else { return p }
            return .keyframes(k.map { Keyframe($0.time * factor, $0.value, $0.interpolation) })
        }
        opacity = scale(opacity); gain = scale(gain)
        transform.position = scale(transform.position); transform.scale = scale(transform.scale)
        transform.rotation = scale(transform.rotation); transform.zoom = scale(transform.zoom)
        transform.focus = scale(transform.focus)
    }
}

/// Adds items without disturbing anything already on the timeline (Final Cut's "connect"): each goes on its preferred
/// track when that span is free, else on the first other track of an accepted kind where it fits, else on a new track.
/// Used for drops, paste, duplicate and new titles.
public struct PlaceItems: EditCommand {
    public struct Placement: Sendable {
        public var item: Item
        /// Track to try first (where the item was copied from, or where it was dropped).
        public var track: TrackID?
        /// Track kinds the item may go on, best first; a new track gets the first kind.
        public var kinds: [TrackKind]
        public init(_ item: Item, track: TrackID? = nil, kinds: [TrackKind]) { self.item = item; self.track = track; self.kinds = kinds }
    }

    public var placements: [Placement]
    public var name: String
    public init(_ placements: [Placement], name: String = "Add") { self.placements = placements; self.name = name }

    public func apply(to timeline: Timeline, context: EditContext) throws -> Timeline {
        guard !placements.isEmpty else { throw EditError.nothingToDo }
        var t = timeline
        for p in placements {
            guard !p.item.range.isEmpty, p.item.start >= .zero else { throw EditError.invalidRange("empty or before timeline start") }
            guard let newKind = p.kinds.first else { throw EditError.invalidRange("no track kind for \(p.item.name)") }
            func fits(_ ti: Int) -> Bool {
                p.kinds.contains(t.tracks[ti].kind) && !t.tracks[ti].locked && !t.tracks[ti].items.contains { $0.range.overlaps(p.item.range) }
            }
            let ti = p.track.flatMap(t.trackIndex).flatMap { fits($0) ? $0 : nil }
                ?? t.tracks.indices.first(where: fits)
                ?? t.addTrack(newKind, context: context)
            t.tracks[ti].items.append(p.item)
            t.tracks[ti].sortItems()
        }
        return t
    }
}

/// Insert edit: opens a gap as long as the item at its start time on every unlocked track (splitting whatever spans that
/// point), so everything after it — captions, music, overlays — stays in sync, then puts the item on `track`.
public struct InsertEdit: EditCommand {
    public var item: Item
    public var track: TrackID
    public init(_ item: Item, on track: TrackID) { self.item = item; self.track = track }
    public var name: String { "Insert \(item.name.isEmpty ? "Clip" : item.name)" }

    public func apply(to timeline: Timeline, context: EditContext) throws -> Timeline {
        guard !item.range.isEmpty, item.start >= .zero else { throw EditError.invalidRange("empty or before timeline start") }
        var t = timeline
        let ti = try t.requireUnlockedTrack(track)
        let at = item.start, d = item.range.duration
        for k in t.tracks.indices where !t.tracks[k].locked {
            if let s = t.tracks[k].items.firstIndex(where: { $0.start < at && at < $0.end }) {
                let spanning = t.tracks[k].items[s]
                guard !spanning.locked else { throw EditError.itemLocked(spanning.id) }
                var tail = spanning.trimmedStart(to: at)
                tail.id = context.makeID()
                t.tracks[k].items[s] = spanning.trimmedEnd(to: at)
                t.tracks[k].items.insert(tail, at: s + 1)
            }
            for i in t.tracks[k].items.indices where t.tracks[k].items[i].start >= at {
                t.tracks[k].items[i].range = t.tracks[k].items[i].range.offset(by: d)
            }
        }
        try t.place(item, onTrack: ti, mode: .reject, context: context)
        return t
    }
}

/// Removes a time range from every unlocked track: a "lift" that leaves a gap, or with `ripple` an "extract" that
/// pulls everything after it left (the In–Out range delete).
public struct RemoveRange: EditCommand {
    public var range: TimeRange
    public var ripple: Bool
    public init(_ range: TimeRange, ripple: Bool) { self.range = range; self.ripple = ripple }
    public var name: String { ripple ? "Ripple Delete Range" : "Delete Range" }

    public func apply(to timeline: Timeline, context: EditContext) throws -> Timeline {
        guard !range.isEmpty else { throw EditError.invalidRange("empty range") }
        var t = timeline
        var changed = false
        for ti in t.tracks.indices where !t.tracks[ti].locked {
            let hits = t.tracks[ti].items.filter { $0.range.overlaps(range) }
            if let locked = hits.first(where: \.locked) { throw EditError.itemLocked(locked.id) }
            for h in hits { try t.clear(range, onTrack: ti, item: h, context: context) }
            changed = changed || !hits.isEmpty
            if ripple {
                for i in t.tracks[ti].items.indices where t.tracks[ti].items[i].start >= range.end {
                    t.tracks[ti].items[i].range = t.tracks[ti].items[i].range.offset(by: -range.duration)
                    changed = true
                }
            }
            t.tracks[ti].sortItems()
        }
        guard changed else { throw EditError.nothingToDo }
        return t
    }
}

/// Moves items left or right in time on their own tracks (the , and . keys). Repeated nudges are one undo step.
public struct NudgeItems: EditCommand {
    public var ids: Set<ItemID>
    public var delta: RationalTime
    public init(_ ids: Set<ItemID>, by delta: RationalTime) { self.ids = ids; self.delta = delta }
    public var name: String { "Nudge" }
    public var coalescingKey: String? { "nudge-" + ids.map(\.uuidString).sorted().joined(separator: ",") }

    public func apply(to timeline: Timeline, context: EditContext) throws -> Timeline {
        var t = timeline
        var found = false
        for ti in t.tracks.indices where t.tracks[ti].items.contains(where: { ids.contains($0.id) }) {
            guard !t.tracks[ti].locked else { throw EditError.trackLocked(t.tracks[ti].id) }
            for i in t.tracks[ti].items.indices where ids.contains(t.tracks[ti].items[i].id) {
                guard !t.tracks[ti].items[i].locked else { throw EditError.itemLocked(t.tracks[ti].items[i].id) }
                t.tracks[ti].items[i].range = t.tracks[ti].items[i].range.offset(by: delta)
                if t.tracks[ti].items[i].start < .zero { throw EditError.invalidRange("before timeline start") }
                found = true
            }
            t.tracks[ti].sortItems()
            if zip(t.tracks[ti].items, t.tracks[ti].items.dropFirst()).contains(where: { $0.range.overlaps($1.range) }) {
                throw EditError.overlap(t.tracks[ti].id)
            }
        }
        guard found else { throw EditError.nothingToDo }
        return t
    }
}

/// Changes a clip's playback speed (0.1×–16×). The same source plays faster or slower, so the item gets shorter or
/// longer from its start; `ripple` moves the following items on its track to match, otherwise growing into a
/// neighbour is an overlap error. Audio keeps its pitch (the compositions use the spectral time-pitch algorithm).
public struct SetSpeed: EditCommand {
    public static let range = 0.1...16.0
    public var id: ItemID
    public var speed: Double
    public var ripple: Bool
    public init(_ id: ItemID, speed: Double, ripple: Bool) { self.id = id; self.speed = speed; self.ripple = ripple }
    public var name: String { "Change Speed" }
    public var coalescingKey: String? { "speed-\(id)" }

    public func apply(to timeline: Timeline, context: EditContext) throws -> Timeline {
        guard Self.range.contains(speed) else { throw EditError.invalidRange("speed \(speed) outside 0.1×–16×") }
        var t = timeline
        guard let loc = t.locate(id) else { throw EditError.itemNotFound(id) }
        let ti = try t.requireUnlockedTrack(t.tracks[loc.track].id)
        var item = t.tracks[ti].items[loc.item]
        guard !item.locked else { throw EditError.itemLocked(id) }
        guard case .media(var m) = item.content else { throw EditError.invalidRange("only clips have a speed") }
        let rate = t.canvas.frameRate
        let old = item.range
        // Whole frames, never longer than the source the clip already uses (so it can't run past the media's end).
        let duration = (m.source.duration * (1 / speed)).floorToFrame(rate)
        guard duration >= rate.frameDuration else { throw EditError.invalidRange("clip would be shorter than a frame") }
        m.speed = speed
        m.source.duration = duration.timesSpeed(speed)
        item.content = .media(m)
        item.range.duration = duration
        item.scaleKeyframes(by: duration.seconds / old.duration.seconds)
        item.fadeIn = .min(item.fadeIn, duration)
        item.fadeOut = .min(item.fadeOut, duration)
        t.tracks[ti].items[loc.item] = item
        if ripple {
            let delta = item.end - old.end
            for i in t.tracks[ti].items.indices where i != loc.item && t.tracks[ti].items[i].start >= old.end {
                t.tracks[ti].items[i].range = t.tracks[ti].items[i].range.offset(by: delta)
            }
        }
        if t.tracks[ti].items.contains(where: { $0.id != id && $0.range.overlaps(item.range) }) { throw EditError.overlap(t.tracks[ti].id) }
        t.tracks[ti].sortItems()
        return t
    }
}

/// Several commands applied in order as one undo step (e.g. locking every selected item, or adding a missing style
/// together with the title that uses it). Fails as a whole if any part fails.
public struct Batch: EditCommand {
    public var commands: [any EditCommand]
    public var name: String
    public init(_ commands: [any EditCommand], name: String) { self.commands = commands; self.name = name }

    public func apply(to timeline: Timeline, context: EditContext) throws -> Timeline {
        guard !commands.isEmpty else { throw EditError.nothingToDo }
        return try commands.reduce(timeline) { try $1.apply(to: $0, context: context) }
    }
}

/// Adds or replaces a text style in the timeline's style sheet.
public struct SetStyle: EditCommand {
    public var key: String
    public var style: TextStyle
    public init(_ key: String, _ style: TextStyle) { self.key = key; self.style = style }
    public var name: String { "Set Style" }
    public func apply(to timeline: Timeline, context: EditContext) throws -> Timeline {
        var t = timeline
        t.styles[key] = style
        return t
    }
}
