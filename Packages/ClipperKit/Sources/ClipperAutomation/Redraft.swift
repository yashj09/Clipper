import ClipperCore
import Foundation

/// Re-running a draft without losing the user's work: a new draft is made from the same clips (with whatever template,
/// variation or options the user picks) and the user's work is carried over — locked items, items they added, and
/// whole locked tracks stay where they were; unlocked automatic items are replaced by the new draft's.
public enum Redraft {
    public struct Result: Sendable {
        public var timeline: Timeline
        /// How many of the old timeline's items were carried over.
        public var kept: Int
    }

    /// The inputs that produced `timeline`: as recorded, or — for timelines drafted before inputs were recorded —
    /// rebuilt from its slot-tagged automatic media (each asset once, in timeline order, trimmed to the part the draft
    /// used). Nil when the timeline wasn't drafted.
    public static func record(of timeline: Timeline) -> DraftRecord? {
        guard let provenance = timeline.provenance else { return nil }
        if let recorded = provenance.inputs { return recorded }
        var order: [AssetID] = []
        var slots: [AssetID: String] = [:]
        var ranges: [AssetID: (Double, Double)] = [:]
        for item in timeline.allItems.sorted(by: { $0.start < $1.start }) where item.origin.isAuto {
            guard let slot = item.slot, case .media(let m) = item.content else { continue }
            if slots[m.asset] == nil { order.append(m.asset); slots[m.asset] = slot }
            let r = ranges[m.asset] ?? (m.source.start.seconds, m.source.end.seconds)
            ranges[m.asset] = (min(r.0, m.source.start.seconds), max(r.1, m.source.end.seconds))
        }
        guard !order.isEmpty else { return nil }
        // The title element is the automatic text the elements pass made (if any).
        let title = timeline.allItems.lazy.compactMap { item -> String? in
            guard item.origin == .auto(pass: "elements"), case .text(let t) = item.content else { return nil }
            return t.text
        }.first
        return DraftRecord(clips: order.map { DraftRecord.Clip(asset: $0, slot: slots[$0], inPoint: ranges[$0]?.0, outPoint: ranges[$0]?.1) },
                           title: title,
                           captions: timeline.tracks.contains { $0.kind == .caption },
                           music: timeline.tracks.contains { $0.kind == .music })
    }

    /// Carries the user's work from `old` into the freshly drafted `fresh`. Kept items go back on the matching track
    /// (same track, else same kind and name, else a recreated one) and win where they overlap new automatic items.
    /// The old timeline's identity, name, extra styles, credits and track settings (mute, hide, lock, gain) are kept.
    public static func merge(_ old: Timeline, into fresh: Timeline, context: EditContext = EditContext()) -> Result {
        var t = fresh
        t.id = old.id
        t.name = old.name
        for (k, v) in old.styles where t.styles[k] == nil { t.styles[k] = v }
        for a in old.attributions where !t.attributions.contains(a) { t.attributions.append(a) }

        var used = Set<TrackID>()
        var keptIDs = Set<ItemID>()
        /// Where each kept item went, so ID clashes are resolved in its favour.
        var keptOn: [ItemID: TrackID] = [:]
        for track in old.tracks {
            let keep = track.locked ? track.items : track.items.filter { $0.origin == .user || $0.locked }
            var ti = t.tracks.firstIndex { $0.id == track.id && !used.contains($0.id) }
                ?? t.tracks.firstIndex { $0.kind == track.kind && $0.name == track.name && !used.contains($0.id) }
            if ti == nil {
                guard !keep.isEmpty else { continue }      // an automatic track the new draft no longer makes
                var empty = track
                empty.items = []
                let i = t.insertionIndex(forNew: track.kind)
                t.tracks.insert(empty, at: i)
                ti = i
            }
            let index = ti!
            let id = t.tracks[index].id
            used.insert(id)
            t.tracks[index].locked = false
            // A locked track comes back exactly as it was, without the new draft's items in its gaps.
            if track.locked { t.tracks[index].items = [] }
            for item in keep {
                // Overwrite clears whatever new automatic item is in the way (splitting it if needed).
                if let out = try? InsertItem(item, on: id, mode: .overwrite).apply(to: t, context: context) {
                    t = out
                    keptIDs.insert(item.id)
                    keptOn[item.id] = id
                }
            }
            guard let i = t.trackIndex(id) else { continue }
            t.tracks[i].muted = track.muted
            t.tracks[i].hidden = track.hidden
            t.tracks[i].locked = track.locked
            t.tracks[i].gain = track.gain
            t.tracks[i].language = t.tracks[i].language ?? track.language
        }

        // The same seed reproduces old IDs, so a new automatic item can share a kept item's ID on another track.
        // IDs must stay unique: kept items keep theirs (selections and references stay valid), the new one is renamed.
        var seen = Set<ItemID>()
        for ti in t.tracks.indices {
            for ii in t.tracks[ti].items.indices {
                let id = t.tracks[ti].items[ii].id
                let isKeptCopy = keptOn[id] == t.tracks[ti].id
                if (keptOn[id] != nil && !isKeptCopy) || !seen.insert(id).inserted {
                    t.tracks[ti].items[ii].id = context.makeID()
                }
            }
        }
        return Result(timeline: t, kept: keptIDs.count)
    }
}
