import ClipperCore
import Foundation

/// A kept piece of a source clip, before placement on the timeline.
struct Segment: Equatable {
    var clip: Int
    var start: Double
    var end: Double
    /// Words inside the segment (source seconds).
    var words: [TranscriptWord]
    var duration: Double { end - start }
    /// Words per second: how "dense" this piece is, for trimming to a max duration.
    var density: Double { duration > 0 ? Double(words.filter { !$0.isFiller }.count) / duration : 0 }
    var hasSpeech: Bool { words.contains { !$0.isFiller } }
}

enum Cutting {
    /// Source ranges to keep for one clip: speech (non-filler words, or detected voice) merged across short pauses,
    /// padded, with long pauses and fillers cut out. Clips with no detected speech are kept whole.
    static func keepRanges(words: [TranscriptWord], speech: [SpeechActivity.Span], clip: ClosedRange<Double>,
                           rule: SilenceCutRule) -> [ClosedRange<Double>] {
        let inClip: (Double, Double) -> Bool = { s, e in e > clip.lowerBound && s < clip.upperBound }
        let kept = words.filter { inClip($0.start, $0.end) && !(rule.removeFillers && $0.isFiller) }
        var intervals: [(Double, Double)]
        if !kept.isEmpty {
            intervals = kept.map { (max($0.start, clip.lowerBound), min($0.end, clip.upperBound)) }
        } else {
            intervals = speech.filter { inClip($0.start, $0.end) }.map { (max($0.start, clip.lowerBound), min($0.end, clip.upperBound)) }
        }
        guard !intervals.isEmpty else { return [clip] }
        intervals.sort { $0.0 < $1.0 }
        let fillers = rule.removeFillers ? words.filter { $0.isFiller && $0.end - $0.start >= 0.12 } : []

        var merged: [(Double, Double)] = [intervals[0]]
        for iv in intervals.dropFirst() {
            let last = merged[merged.count - 1]
            let gap = iv.0 - last.1
            let fillerInGap = fillers.contains { $0.start >= last.1 - 0.02 && $0.end <= iv.0 + 0.02 }
            if gap < rule.minGap && !fillerInGap { merged[merged.count - 1].1 = max(last.1, iv.1) } else { merged.append(iv) }
        }
        // Pad, clamp to the clip, then merge pads that now touch.
        var padded: [(Double, Double)] = []
        for (s, e) in merged {
            let p = (max(clip.lowerBound, s - rule.padBefore), min(clip.upperBound, e + rule.padAfter))
            if let last = padded.last, p.0 <= last.1 { padded[padded.count - 1].1 = max(last.1, p.1) } else { padded.append(p) }
        }
        return padded.filter { $0.1 - $0.0 >= 0.1 }.map { $0.0...$0.1 }
    }

    static func segments(for clipIndex: Int, clip: ClipInput, rule: SilenceCutRule?) -> [Segment] {
        let words = clip.analysis.transcript?.words ?? []
        let speech = clip.analysis.speech?.spans ?? []
        let ranges = rule.map { keepRanges(words: words, speech: speech, clip: clip.range, rule: $0) } ?? [clip.range]
        return ranges.map { r in
            Segment(clip: clipIndex, start: r.lowerBound, end: r.upperBound,
                    words: words.filter { $0.start >= r.lowerBound - 0.05 && $0.end <= r.upperBound + 0.05 })
        }
    }

    /// Clips without speech (B-roll) are trimmed to their middle `maxLength` seconds.
    static func trimSilent(_ segments: [Segment], maxLength: Double) -> [Segment] {
        segments.map { seg in
            guard !seg.hasSpeech, seg.duration > maxLength else { return seg }
            var s = seg
            let mid = (seg.start + seg.end) / 2
            s.start = mid - maxLength / 2; s.end = mid + maxLength / 2
            return s
        }
    }

    /// Drops the least dense segments (never the first: it carries the hook) until the total fits,
    /// then trims the last segment at a word boundary if needed.
    static func fit(_ segments: [Segment], maxDuration: Double, report: inout DraftReport) -> [Segment] {
        var segs = segments
        var total = segs.reduce(0) { $0 + $1.duration }
        guard total > maxDuration else { return segs }
        var dropped = 0
        while total > maxDuration, segs.count > 1 {
            let candidates = segs.indices.dropFirst()
            guard let worst = candidates.min(by: { (segs[$0].density, -Double($0)) < (segs[$1].density, -Double($1)) }) else { break }
            total -= segs[worst].duration
            segs.remove(at: worst)
            dropped += 1
        }
        if total > maxDuration, var last = segs.popLast() {
            let budget = maxDuration - (total - last.duration)
            var end = last.start + budget
            if let w = last.words.last(where: { $0.end <= end }) { end = min(end, w.end + 0.12) }
            last.end = max(last.start + 0.2, end)
            last.words = last.words.filter { $0.end <= last.end }
            segs.append(last)
        }
        report.notes.append(String(format: "Trimmed to %.1fs (max %.0fs) by dropping %d low-density segment%@",
                                   segs.reduce(0) { $0 + $1.duration }, maxDuration, dropped, dropped == 1 ? "" : "s"))
        return segs
    }

    /// Moves each cut, and the final end, onto the nearest timeline beat when it is within `rule.tolerance`, by moving
    /// the end of the segment before it. Earlier moves shift later cuts, so each cut is measured after the previous
    /// snap. A cut stays put rather than cross a word, leave the clip, or overlap the next piece of the same clip.
    static func beatSnap(_ segments: [Segment], beats: [Double], rule: BeatSnapRule,
                         clips: [ClipInput]) -> (segments: [Segment], moved: Int) {
        var segs = segments
        var moved = 0
        var cut = 0.0
        for k in segs.indices {
            cut += segs[k].duration
            guard let beat = beats.min(by: { abs($0 - cut) < abs($1 - cut) }) else { break }
            let delta = beat - cut
            guard delta != 0, abs(delta) <= rule.tolerance else { continue }
            let seg = segs[k]
            let clip = clips[seg.clip]
            let words = clip.analysis.transcript?.words ?? []
            let newEnd = seg.end + delta
            var limit = clip.range.upperBound
            if k + 1 < segs.count, segs[k + 1].clip == seg.clip, segs[k + 1].start >= seg.end { limit = min(limit, segs[k + 1].start) }
            let lo = min(seg.end, newEnd), hi = max(seg.end, newEnd)
            guard newEnd <= limit, newEnd - seg.start >= 0.1,
                  !words.contains(where: { $0.start < hi && $0.end > lo }) else { continue }
            segs[k].end = newEnd
            segs[k].words = words.filter { $0.start >= seg.start - 0.05 && $0.end <= newEnd + 0.05 }
            cut += delta
            moved += 1
        }
        return (segs, moved)
    }

    /// Montage cutting: each clip occupies a whole number of beats (every `rule.everyBeats`, fewer if the clip is short).
    /// Beats are timeline seconds (music already aligned so its first used beat is at 0). Clips are cycled, advancing
    /// through each source on reuse, until `target` is filled.
    static func beatCut(clips: [ClipInput], beats: [Double], target: Double, rule: BeatCutRule) -> [Segment] {
        guard !clips.isEmpty else { return [] }
        let grid = beats.filter { $0 >= 0 && $0 <= target + 0.001 }
        var segments: [Segment] = []
        var offsets = [Double](repeating: 0, count: clips.count)
        var b = 0, k = 0, guardCount = 0
        while b < grid.count - 1, guardCount < 10_000 {
            guardCount += 1
            let ci = k % clips.count
            let clip = clips[ci]
            let available = clip.range.upperBound - (clip.range.lowerBound + offsets[ci])
            var n = rule.everyBeats
            while n > 1, (b + n >= grid.count || grid[b + n] - grid[b] > available) { n -= 1 }
            guard b + n < grid.count else { break }
            let length = grid[b + n] - grid[b]
            if length < rule.minClip, n == rule.everyBeats { break }
            if available < length {
                // Clip exhausted: rewind it and move on to the next clip.
                offsets[ci] = 0
                k += 1
                if offsets.allSatisfy({ $0 == 0 }) && clips.allSatisfy({ $0.range.upperBound - $0.range.lowerBound < length }) { break }
                continue
            }
            let start = clip.range.lowerBound + offsets[ci]
            segments.append(Segment(clip: ci, start: start, end: start + length, words: []))
            offsets[ci] += length
            b += n
            k += 1
        }
        return segments
    }
}
