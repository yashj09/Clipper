import ClipperCore
import Foundation

/// A kept piece of a source clip, before placement on the timeline. A sped-up pause has `speed > 1`, no words, and
/// abuts the speech on both sides, so the footage plays on without a cut.
struct Segment: Equatable {
    var clip: Int
    var start: Double
    var end: Double
    /// Words inside the segment (source seconds), with their emphasis cues.
    var words: [SpokenWord]
    var speed: Double = 1
    /// Source seconds.
    var duration: Double { end - start }
    var timelineDuration: Double { duration / speed }
    /// Words per second: how "dense" this piece is, for trimming to a max duration.
    var density: Double { duration > 0 ? Double(words.filter { !$0.isFiller }.count) / duration : 0 }
    var hasSpeech: Bool { words.contains { !$0.isFiller } }
    /// The brief's score of the most important sentence spoken here; nil without words or when any word is unscored.
    var importance: Double? {
        let scores = words.compactMap(\.importance)
        return !words.isEmpty && scores.count == words.count ? scores.max() : nil
    }
}

enum Cutting {
    struct Piece: Equatable {
        var range: ClosedRange<Double>
        /// 1 for speech; the rule's rate for a pause kept and played fast.
        var speed: Double = 1
    }

    /// Source ranges to keep for one clip: speech (non-filler words, or detected voice) merged across short pauses,
    /// padded, with long pauses and fillers cut out. Fillers are transcribed ones plus voiced stretches with no word.
    /// Clips with no detected speech are kept whole. No returned range intersects `excluded`: words in it are not
    /// kept, no merge crosses it, and padding is cut back at its edges.
    ///
    /// With `rule.speedUp`, a cut pause no longer than `maxPause`, with no filler or excluded range in it, comes back
    /// as a fast piece filling exactly the space between the padded speech on either side. The speech pieces are the
    /// same as without the rule.
    static func keepRanges(words: [TranscriptWord], speech: SpeechActivity?, clip: ClosedRange<Double>,
                           rule: SilenceCutRule, excluded: RangeSet<Double> = RangeSet()) -> [Piece] {
        let inClip: (Double, Double) -> Bool = { s, e in e > clip.lowerBound && s < clip.upperBound }
        let kept = words.filter {
            inClip($0.start, $0.end) && !(rule.removeFillers && $0.isFiller) && !excluded.contains(($0.start + $0.end) / 2)
        }
        var intervals: [(Double, Double)]
        if !kept.isEmpty {
            intervals = kept.map { (max($0.start, clip.lowerBound), min($0.end, clip.upperBound)) }
        } else {
            intervals = (speech?.spans ?? []).filter { inClip($0.start, $0.end) }.map { (max($0.start, clip.lowerBound), min($0.end, clip.upperBound)) }
        }
        guard !intervals.isEmpty else { return subtracting(excluded, from: [clip]).map { Piece(range: $0) } }
        intervals.sort { $0.0 < $1.0 }
        var fillers = rule.removeFillers ? words.filter { $0.isFiller && $0.end - $0.start >= 0.12 }.map { ($0.start, $0.end) } : []
        // Without words the voice spans are the speech itself, and every one of them would count as unworded.
        if rule.removeFillers, !kept.isEmpty, let speech {
            fillers += Fillers.unworded(activity: speech, words: words, minDuration: 0.2)
                .filter { inClip($0.start, $0.end) }.map { (max($0.start, clip.lowerBound), min($0.end, clip.upperBound)) }
        }

        let speedUp = rule.speedUp.flatMap { $0.rate > 1 ? $0 : nil }
        var merged: [(Double, Double)] = [intervals[0]]
        var fastGapBefore: Set<Int> = []
        for iv in intervals.dropFirst() {
            let last = merged[merged.count - 1]
            let gap = iv.0 - last.1
            let fillerInGap = fillers.contains { $0.0 >= last.1 - 0.02 && $0.1 <= iv.0 + 0.02 }
            let excludedInGap = iv.0 > last.1 && !excluded.isDisjoint(RangeSet(last.1..<iv.0))
            if gap < rule.minGap && !fillerInGap && !excludedInGap {
                merged[merged.count - 1].1 = max(last.1, iv.1)
            } else {
                if let speedUp, gap <= speedUp.maxPause, !fillerInGap, !excludedInGap { fastGapBefore.insert(merged.count) }
                merged.append(iv)
            }
        }
        // Pad, clamp to the clip, then merge pads that now touch.
        var padded: [(Double, Double)] = []
        var pauses: [(Double, Double)] = []
        for (i, (s, e)) in merged.enumerated() {
            let p = (max(clip.lowerBound, s - rule.padBefore), min(clip.upperBound, e + rule.padAfter))
            if let last = padded.last, p.0 <= last.1 {
                padded[padded.count - 1].1 = max(last.1, p.1)
            } else {
                if fastGapBefore.contains(i), let last = padded.last, p.0 - last.1 >= 0.1 { pauses.append((last.1, p.0)) }
                padded.append(p)
            }
        }
        let speechPieces = subtracting(excluded, from: padded.map { $0.0...$0.1 })
        var pieces: [Piece] = []
        for r in speechPieces {
            // Pauses hold no excluded time, so the speech either side keeps its padded edge exactly.
            if let speedUp, let last = pieces.last, pauses.contains(where: { $0.0 == last.range.upperBound && $0.1 == r.lowerBound }) {
                pieces.append(Piece(range: last.range.upperBound...r.lowerBound, speed: min(speedUp.rate, 16)))
            }
            pieces.append(Piece(range: r))
        }
        return pieces
    }

    /// `ranges` with `excluded` cut out, dropping slivers under 0.1 s.
    static func subtracting(_ excluded: RangeSet<Double>, from ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        let left = RangeSet(ranges.map { $0.lowerBound..<$0.upperBound }).subtracting(excluded)
        return left.ranges.filter { $0.upperBound - $0.lowerBound >= 0.1 }.map { $0.lowerBound...$0.upperBound }
    }

    /// Without a silence-cut rule the clip is kept whole, less what the plan excludes. Segment words come from the
    /// plan, so cues ride along to layout.
    static func segments(for clipIndex: Int, clip: ClipInput, rule: SilenceCutRule?, plan: SpeechPlan) -> [Segment] {
        let words = clip.analysis.transcript?.words ?? []
        let pieces = rule.map { keepRanges(words: words, speech: clip.analysis.speech, clip: clip.range, rule: $0, excluded: plan.excluded) }
            ?? subtracting(plan.excluded, from: [clip.range]).map { Piece(range: $0) }
        return pieces.map { p in
            let r = p.range
            // A fast pause carries no words, not even a dropped short filler: word timing assumes real-time playback.
            let words = p.speed == 1 ? plan.words.filter { $0.start >= r.lowerBound - 0.05 && $0.end <= r.upperBound + 0.05 } : []
            return Segment(clip: clipIndex, start: r.lowerBound, end: r.upperBound, words: words, speed: p.speed)
        }
    }

    /// Speech segments split where one sentence ends and the next begins, at the middle of the pause between them, so
    /// trimming and reordering move whole sentences. The pieces are source-contiguous: `joinContinuous` puts back
    /// whatever stays together. A pause under 0.08 s leaves no clean place to cut, so both sentences stay in one piece.
    static func splitAtSentences(_ segments: [Segment]) -> [Segment] {
        segments.flatMap { seg -> [Segment] in
            guard seg.speed == 1 else { return [seg] }
            var out: [Segment] = []
            var piece = seg
            piece.words = []
            for w in seg.words {
                if let last = piece.words.last, last.sentence != w.sentence, w.start - last.end >= 0.08 {
                    let mid = (last.end + w.start) / 2
                    var done = piece
                    done.end = mid
                    out.append(done)
                    piece.start = mid
                    piece.words = []
                }
                piece.words.append(w)
            }
            out.append(piece)
            return out
        }
    }

    /// Neighbours that play one clip straight through at one speed, merged back into one segment.
    static func joinContinuous(_ segments: [Segment]) -> [Segment] {
        var out: [Segment] = []
        for seg in segments {
            if let last = out.last, last.clip == seg.clip, last.speed == seg.speed, last.end == seg.start {
                out[out.count - 1].end = seg.end
                out[out.count - 1].words += seg.words
            } else {
                out.append(seg)
            }
        }
        return out
    }

    /// Clips without speech (B-roll) are trimmed to their middle `maxLength` seconds.
    static func trimSilent(_ segments: [Segment], maxLength: Double) -> [Segment] {
        segments.map { seg in
            guard seg.speed == 1, !seg.hasSpeech, seg.duration > maxLength else { return seg }
            var s = seg
            let mid = (seg.start + seg.end) / 2
            s.start = mid - maxLength / 2; s.end = mid + maxLength / 2
            return s
        }
    }

    /// Whether the brief scores all the speech here, so trimming can go by importance. Fast pauses never have words.
    static func scored<C: Collection<Segment>>(_ segments: C) -> Bool {
        segments.contains { $0.importance != nil } && segments.allSatisfy { $0.speed != 1 || $0.importance != nil }
    }

    /// Drops segments (never the first: it carries the hook) until the total fits, then trims the last segment at a
    /// word boundary if needed. With a brief scoring every candidate, the least important go first, ties to the least
    /// dense; otherwise the least dense. Ties go to the latest. Fast pauses go before any speech, each leaving the hard
    /// cut the pause would have had without the speed-up.
    static func fit(_ segments: [Segment], maxDuration: Double, report: inout DraftReport) -> [Segment] {
        var segs = segments
        var total = segs.reduce(0) { $0 + $1.timelineDuration }
        guard total > maxDuration else { return segs }
        let byImportance = scored(segs.dropFirst())
        func rank(_ i: Int) -> (Int, Double, Double, Double) {
            let s = segs[i]
            return (s.speed == 1 ? 1 : 0, byImportance ? s.importance ?? 0 : 0, s.density, -Double(i))
        }
        var dropped = 0, droppedSpeech = 0
        while total > maxDuration, segs.count > 1 {
            guard let worst = segs.indices.dropFirst().min(by: { rank($0) < rank($1) }) else { break }
            total -= segs[worst].timelineDuration
            if segs[worst].speed == 1 { droppedSpeech += 1 }
            segs.remove(at: worst)
            dropped += 1
        }
        if total > maxDuration, var last = segs.popLast() {
            let budget = maxDuration - (total - last.timelineDuration)
            var end = last.start + budget * last.speed
            if let w = last.words.last(where: { $0.end <= end }) { end = min(end, w.end + 0.12) }
            last.end = max(last.start + 0.2, end)
            last.words = last.words.filter { $0.end <= last.end }
            segs.append(last)
        }
        let fitted = segs.reduce(0) { $0 + $1.timelineDuration }
        report.notes.append(byImportance
            ? String(format: "Trimmed to %.1fs (max %.0fs) by dropping %d low-importance sentence%@",
                     fitted, maxDuration, droppedSpeech, droppedSpeech == 1 ? "" : "s")
            : String(format: "Trimmed to %.1fs (max %.0fs) by dropping %d low-density segment%@",
                     fitted, maxDuration, dropped, dropped == 1 ? "" : "s"))
        return segs
    }

    /// Moves each cut, and the final end, onto the nearest timeline beat when it is within `rule.tolerance`, by moving
    /// the end of the segment before it. Earlier moves shift later cuts, so each cut is measured after the previous
    /// snap. A cut stays put rather than cross a word, leave the clip, or overlap the next piece of the same clip.
    /// Both ends of a fast pause stay put: moving one would open a gap in footage that plays straight through.
    static func beatSnap(_ segments: [Segment], beats: [Double], rule: BeatSnapRule,
                         clips: [ClipInput]) -> (segments: [Segment], moved: Int) {
        var segs = segments
        var moved = 0
        var cut = 0.0
        for k in segs.indices {
            cut += segs[k].timelineDuration
            guard segs[k].speed == 1, k + 1 == segs.count || segs[k + 1].speed == 1 else { continue }
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
            segs[k].words = seg.words.filter { $0.end <= newEnd + 0.05 }
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
