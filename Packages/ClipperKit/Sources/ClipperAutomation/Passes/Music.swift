import ClipperCore
import Foundation

enum Music {
    /// Scores tracks by mood/genre overlap, tempo range, length and energy; ties break deterministically by seed.
    static func pick(_ pool: [MusicTrack], policy: MusicPolicy, target: Double, wantEnergy: Double?,
                     forced: String?, seed: UInt64) -> MusicTrack? {
        if let forced, let t = pool.first(where: { $0.id == forced }) { return t }
        let candidates = pool.filter { $0.duration >= 5 }
        guard !candidates.isEmpty else { return nil }
        func norm(_ s: [String]) -> Set<String> { Set(s.map { $0.lowercased() }) }
        let moods = norm(policy.moods), genres = norm(policy.genres)
        func score(_ t: MusicTrack) -> Double {
            var s = 2 * Double(norm(t.moods).intersection(moods).count) + Double(norm(t.genres).intersection(genres).count)
            if let bpm = t.bpm {
                let lo = policy.minBPM ?? 0, hi = policy.maxBPM ?? 1000
                s += (lo...hi).contains(bpm) ? 2 : -min(abs(bpm - lo), abs(bpm - hi)) / 20
            }
            s += t.duration >= target ? 2 : -1          // looping is possible but a full-length track is nicer
            if let want = wantEnergy, let e = t.energy { s -= 2 * abs(want - e) }
            if case .owned = t.license { s += 0.5 }      // prefer the user's own library on ties
            // Deterministic jitter so the same inputs always pick the same track, but different seeds vary.
            s += Double(stableHash("\(seed)|\(t.id)") % 1000) / 10_000
            return s
        }
        return candidates.max { score($0) < score($1) }
    }

    /// Where to start inside the track: the first downbeat (or beat) within the first 4 s, so cuts land on beats.
    static func startOffset(_ track: MusicTrack, alignToBeat: Bool) -> Double {
        guard alignToBeat, let grid = track.beats else { return 0 }
        if let d = grid.downbeats.first(where: { $0 <= 4 }) { return d }
        return grid.beats.first(where: { $0 <= 4 }) ?? 0
    }

    /// Beat times on the timeline when the track starts playing from `offset` at timeline 0 (looping included).
    static func timelineBeats(_ track: MusicTrack, offset: Double, until end: Double) -> [Double] {
        guard let beats = track.beats?.beats, !beats.isEmpty else { return [] }
        var out: [Double] = []
        let loopLength = track.duration - offset
        guard loopLength > 1 else { return [] }
        var base = 0.0
        while base < end {
            out += beats.filter { $0 >= offset }.map { $0 - offset + base }.filter { $0 <= end }
            base += loopLength
        }
        return out
    }

    /// Music items covering [0, duration): the track from `offset`, looping if it is shorter than the timeline.
    static func items(_ track: MusicTrack, assetID: AssetID, offset: Double, duration: Double, policy: MusicPolicy,
                      rate: FrameRate, ids: inout IDGenerator) -> [Item] {
        var items: [Item] = []
        var t = 0.0
        while t < duration - 0.05 {
            let length = min(track.duration - offset, duration - t)
            guard length > 0.05 else { break }
            let start = RationalTime.frames(t, rate), end = RationalTime.frames(t + length, rate)
            guard start < end else { break }
            let range = TimeRange(start: start, end: end)
            items.append(Item(id: ids.uuid(), name: track.title, range: range,
                              content: .media(MediaRef(asset: assetID, source: TimeRange(start: RationalTime(seconds: offset), duration: range.duration))),
                              gain: .constant(policy.gain), origin: .auto(pass: "music")))
            t += length
        }
        if !items.isEmpty {
            items[0].fadeIn = RationalTime.frames(policy.fadeIn, rate)
            items[items.count - 1].fadeOut = RationalTime.frames(min(policy.fadeOut, items[items.count - 1].range.duration.seconds / 2), rate)
        }
        return items
    }

    /// Lowers music under speech: gain keyframes dipping by `depth` dB with attack/release ramps.
    static func duck(_ items: [Item], speech: [(Double, Double)], rule: DuckRule, baseGain: Double) -> [Item] {
        // Merge spans whose release and next attack would overlap.
        var spans: [(Double, Double)] = []
        for s in speech.sorted(by: { $0.0 < $1.0 }) {
            if let last = spans.last, s.0 - rule.attack <= last.1 + rule.release { spans[spans.count - 1].1 = max(last.1, s.1) }
            else { spans.append(s) }
        }
        let low = baseGain - rule.depth
        return items.map { item in
            var keys: [Keyframe<Double>] = []
            let a = item.start.seconds, b = item.end.seconds
            func key(_ t: Double, _ v: Double) {
                let local = min(max(t - a, 0), b - a)
                if let last = keys.last, RationalTime(seconds: local) <= last.time { return }
                keys.append(Keyframe(RationalTime(seconds: local), v, .linear))
            }
            for (s, e) in spans where e + rule.release > a && s - rule.attack < b {
                key(s - rule.attack, baseGain)
                key(s, low)
                key(e, low)
                key(e + rule.release, baseGain)
            }
            var out = item
            if !keys.isEmpty {
                if keys[0].time > .zero { keys.insert(Keyframe(.zero, keys[0].value == low ? low : baseGain, .linear), at: 0) }
                out.gain = Param.from(keys)
            }
            return out
        }
    }
}
