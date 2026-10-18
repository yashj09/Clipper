import ClipperCore
import Foundation

/// The primary track's zoom over timeline time, as a factor on each item's own zoom (1 = the template's framing).
struct ZoomCurve: Equatable {
    struct Move: Equatable {
        enum Reason: Equatable { case emphasis, pacing }
        var start: Double
        /// 0 only when `start` is a cut: the cut hides the step.
        var duration: Double
        var to: Double
        var reason: Reason
        /// Emphasis punches ease; pacing pushes drift at a steady rate.
        var interpolation: Interpolation { reason == .pacing ? .linear : .easeInOut }
    }
    /// Sorted. Each move ends before the next starts, and no move straddles a cut. A move may straddle the boundary
    /// between items that play continuously.
    var moves: [Move]

    func value(at t: Double) -> Double {
        var level = 1.0
        for m in moves {
            if t < m.start { break }
            if t < m.start + m.duration {
                let ramp = Param.keyframes([Keyframe(.zero, level, m.interpolation), Keyframe(RationalTime(seconds: m.duration), m.to)])
                return ramp.value(at: RationalTime(seconds: t - m.start))
            }
            level = m.to
        }
        return level
    }

    /// Keyframes relative to the item's start, times `base`. A move already under way at the start finishes from
    /// where it is. A flat result collapses to a constant.
    func zoom(over range: TimeRange, base: Double) -> Param<Double> {
        let t0 = range.start.seconds, t1 = range.end.seconds
        var keys = [Keyframe(.zero, base * value(at: t0), .hold)]
        for m in moves where m.duration > 0 && m.start + m.duration > t0 && m.start < t1 {
            let from = Keyframe(RationalTime(seconds: max(0, m.start - t0)), base * value(at: max(m.start, t0)), m.interpolation)
            if keys[keys.count - 1].time == from.time { keys[keys.count - 1] = from } else { keys.append(from) }
            keys.append(Keyframe(RationalTime(seconds: m.start + m.duration - t0), base * m.to, .hold))
        }
        return Param.from(keys)
    }
}

extension Visual {
    /// Zoom moves for words on a timeline cut at `cuts`. Two clocks: `minSpacing` separates zoom changes, and
    /// `maxStill` bounds the time without any visual change, cut or zoom. An emphasis word (any cue) zooms when the
    /// spacing allows, alternating in and out, and steps on a cut that lands just before it so the cut hides the
    /// jump. A stretch longer than `maxStill` gets a pacing move: a slow push in, or a step back out when already in.
    static func zoomCurve(words: [TimedWord], cuts: [Double], end: Double, rule: PunchInRule) -> ZoomCurve {
        let still = rule.maxStill > 0 ? max(rule.maxStill, rule.minSpacing) : .infinity
        let ramp = min(rule.rampDuration, rule.minSpacing)
        let cuts = cuts.sorted()
        let spoken = words.filter { !$0.isFiller }.sorted { $0.start < $1.start }
        var moves: [ZoomCurve.Move] = []
        var level = 1.0, lastZoom = -Double.infinity, lastChange = 0.0, moveEnd = 0.0
        var c = 0
        func nextCut(after t: Double) -> Double { cuts.first { $0 > t } ?? end }
        func move(_ t: Double, duration: Double, to: Double, _ reason: ZoomCurve.Move.Reason) {
            moves.append(.init(start: t, duration: duration, to: to, reason: reason))
            level = to; lastZoom = t; lastChange = t; moveEnd = t + duration
        }
        func pacing(at t: Double) {
            if level >= rule.zoom {
                move(t, duration: min(ramp, nextCut(after: t) - t), to: 1, .pacing)
            } else {
                move(t, duration: min(rule.minSpacing, nextCut(after: t) - t), to: min(level * 1.05, rule.zoom * 1.05), .pacing)
            }
        }
        // A pause of up to half a second waits for the next word, so pacing moves land on speech when there is any.
        func fillStills(before t: Double) {
            while lastChange + still + 0.5 < t, lastChange + still < end { pacing(at: lastChange + still) }
        }
        for w in spoken where w.start < end {
            let t = w.start
            while c < cuts.count, cuts[c] <= t {
                fillStills(before: cuts[c])
                lastChange = max(lastChange, cuts[c])
                c += 1
            }
            fillStills(before: t)
            guard t >= moveEnd else { continue }
            if w.cue.zooms, t - lastZoom >= rule.minSpacing {
                let target = level < (1 + rule.zoom) / 2 ? rule.zoom : 1
                if let cut = cuts.last(where: { $0 <= t }), t - cut <= ramp, cut >= moveEnd, cut - lastZoom >= rule.minSpacing {
                    move(cut, duration: 0, to: target, .emphasis)
                } else {
                    move(t, duration: min(ramp, nextCut(after: t) - t), to: target, .emphasis)
                }
            } else if t - lastChange >= still {
                pacing(at: t)
            }
        }
        while c < cuts.count {
            fillStills(before: cuts[c])
            lastChange = max(lastChange, cuts[c])
            c += 1
        }
        fillStills(before: end)
        return ZoomCurve(moves: moves)
    }

    /// Writes the curve into the items' `transform.zoom`, on top of each item's own constant zoom. `cuts` are the
    /// timeline times where the footage jumps, which are not every item start: a fast pause plays straight on.
    /// Items whose zoom is already keyframed are left alone.
    static func zooms(_ items: [Item], words: [TimedWord], cuts: [Double], rule: PunchInRule) -> (items: [Item], note: String?) {
        guard let last = items.last else { return (items, nil) }
        let curve = zoomCurve(words: words, cuts: cuts, end: last.end.seconds, rule: rule)
        var out = items
        for i in out.indices where !out[i].transform.zoom.isAnimated {
            out[i].transform.zoom = curve.zoom(over: out[i].range, base: out[i].transform.zoom.value(at: .zero))
        }
        let emphasis = curve.moves.filter { $0.reason == .emphasis }.count
        guard !curve.moves.isEmpty else { return (out, nil) }
        let n = curve.moves.count
        return (out, "Added \(n) zoom\(n == 1 ? "" : "s") (\(emphasis) on emphasis, \(n - emphasis) for pacing)")
    }
}
