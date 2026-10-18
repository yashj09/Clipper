import ClipperCore
import Foundation

extension Cutting {
    /// Source ranges of `clip` where consecutive visual samples are blurry or badly exposed for at least
    /// `rule.minSeconds`. Each sample stands for the time halfway to its neighbours. A sample without sharpness or luma
    /// (an artifact from before they were measured) is never bad on that count. A stretch with a spoken word in
    /// `sparing` stays: a soft shot is better than a cut sentence.
    static func badRanges(_ clip: ClipInput, rule: BadShotRule, sparing words: [SpokenWord] = []) -> [ClosedRange<Double>] {
        let range = clip.range
        let samples = (clip.analysis.visual?.samples ?? []).filter { range.contains($0.time) }.sorted { $0.time < $1.time }
        let gaps = zip(samples, samples.dropFirst()).map { $1.time - $0.time }.sorted()
        let half = (gaps.isEmpty ? 1 : gaps[gaps.count / 2]) / 2
        func bad(_ s: VisualSample) -> Bool {
            if let v = s.sharpness, v < rule.minSharpness { return true }
            if let l = s.luma, l < rule.minLuma || l > rule.maxLuma { return true }
            return false
        }
        var out: [ClosedRange<Double>] = []
        var i = 0
        while i < samples.count {
            guard bad(samples[i]) else { i += 1; continue }
            var j = i
            while j + 1 < samples.count, bad(samples[j + 1]) { j += 1 }
            let lo = max(range.lowerBound, samples[i].time - half), hi = min(range.upperBound, samples[j].time + half)
            if hi - lo >= rule.minSeconds, !words.contains(where: { !$0.isFiller && $0.end > lo && $0.start < hi }) {
                out.append(lo...hi)
            }
            i = j + 1
        }
        return out
    }

    /// `clip` without `bad`, as clips trimmed to each good stretch of at least `minLength` seconds.
    static func splitting(_ clip: ClipInput, around bad: [ClosedRange<Double>], minLength: Double) -> [ClipInput] {
        guard !bad.isEmpty else { return [clip] }
        let good = RangeSet([clip.range.lowerBound..<clip.range.upperBound])
            .subtracting(RangeSet(bad.map { $0.lowerBound..<$0.upperBound }))
        return good.ranges.filter { $0.upperBound - $0.lowerBound >= minLength }.map { r in
            var c = clip
            c.inPoint = r.lowerBound; c.outPoint = r.upperBound
            return c
        }
    }
}
