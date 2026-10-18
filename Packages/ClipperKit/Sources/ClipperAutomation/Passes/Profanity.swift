import ClipperCore
import Foundation

extension SpeechPlan {
    mutating func markProfanity(locale: String) {
        for i in words.indices where !words[i].isFiller && Profanity.isProfane(words[i].text, locale: locale) {
            words[i].cue.insert(.profane)
        }
    }
}

extension Visual {
    /// Primary items with the gain 60 dB down from 30 ms before each profane word to 30 ms after it, ramping over
    /// 10 ms like the declick at a cut and never louder than the item's own gain. `spans` are the silenced stretches,
    /// timeline seconds, for bleeps.
    static func muteProfanity(_ items: [Item], words: [TimedWord], base: Double) -> (items: [Item], spans: [(Double, Double)], words: Int) {
        let profane = words.filter { $0.cue.contains(.profane) }.sorted { $0.start < $1.start }
        let ramp = 0.01
        var spans: [(Double, Double)] = []
        for w in profane {
            let s = (w.start - 0.03, w.end + 0.03)
            if let last = spans.last, s.0 - ramp <= last.1 + ramp { spans[spans.count - 1].1 = max(last.1, s.1) } else { spans.append(s) }
        }
        let out = items.map { item -> Item in
            let a = item.start.seconds, d = item.range.duration.seconds
            let local = spans.map { ($0.0 - a, $0.1 - a) }.filter { $0.1 + ramp > 0 && $0.0 - ramp < d }
            guard !local.isEmpty else { return item }
            // 0 at full level, 1 at the full 60 dB dip.
            func depth(_ t: Double) -> Double {
                local.reduce(0) { m, s in max(m, min(1, max(0, min((t - (s.0 - ramp)) / ramp, ((s.1 + ramp) - t) / ramp)))) }
            }
            var times = Set(item.gain.keys.map(\.time.seconds) + [0, d])
            for s in local { for t in [s.0 - ramp, s.0, s.1, s.1 + ramp] where t > 0 && t < d { times.insert(t) } }
            let keys = times.sorted().map { t in
                let time = RationalTime(seconds: t)
                return Keyframe(time, min(item.gain.value(at: time), base - 60 * depth(t)), .linear)
            }
            var muted = item
            muted.gain = Param.from(keys)
            return muted
        }
        return (out, spans, profane.count)
    }

    /// A bleep over each silenced span, as long as the span or the effect, whichever is shorter.
    static func bleeps(_ spans: [(Double, Double)], asset: MediaAsset, duration: Double, rate: FrameRate, ids: inout IDGenerator) -> [Item] {
        spans.compactMap { s in
            // Near speech level: the effect peaks at −6 dBFS.
            effectItem(asset, at: max(0, s.0), until: min(s.1, duration), gain: -6, pass: "profanity", rate: rate, ids: &ids)
        }
    }

    /// `asset` from its start at `time`, cut short at `until` and onto the frame grid, with a 10 ms fade when cut short
    /// so the cut does not click.
    static func effectItem(_ asset: MediaAsset, at time: Double, until: Double, gain: Double, pass: String, rate: FrameRate,
                           ids: inout IDGenerator) -> Item? {
        let start = RationalTime.frames(time, rate)
        // Floored, so the source never runs past the end of the file.
        let end = RationalTime(seconds: min(start.seconds + asset.info.duration.seconds, until)).floorToFrame(rate)
        guard end > start else { return nil }
        let range = TimeRange(start: start, end: end)
        var item = Item(id: ids.uuid(), name: asset.name, range: range,
                        content: .media(MediaRef(asset: asset.id, source: TimeRange(start: .zero, duration: range.duration))),
                        gain: .constant(gain), origin: .auto(pass: pass))
        if range.duration < asset.info.duration { item.fadeOut = RationalTime(value: 1, scale: 100) }
        return item
    }
}
