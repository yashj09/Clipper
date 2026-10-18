import ClipperCore
import Foundation

/// Cutaways to the user's own clips at the words that name them: a spoken "camera" cuts to `camera-closeup.mov` for a
/// moment, muted, then back to the speaker.
enum BRoll {
    struct Placement: Equatable {
        var items: [Item] = []
        /// Candidate names in the order they were first shown.
        var used: [String] = []
        /// Some spoken keyword named a candidate, placed or not.
        var matched = false

        var note: String? {
            items.isEmpty ? nil : String(format: "Added %d B-roll cutaway%@ (%@)", items.count, items.count == 1 ? "" : "s",
                                         used.joined(separator: ", "))
        }
        var warning: String? {
            !items.isEmpty ? nil : matched ? "B-roll: every keyword that matched a clip fell on the title, the hook or the last 1.5 s"
                : "B-roll: no clip name or tag matched a spoken keyword"
        }
    }

    /// Words in file names that say nothing about what a clip shows.
    static let stopWords: Set<String> = ["clip", "video", "mov", "final", "edit", "take", "broll", "roll"]

    /// Lowercased letter runs of `text`, singular, at least 3 letters, stop words dropped: "Camera B-roll 2.mov" → camera.
    static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter }.map { singular(String($0)) }.filter { $0.count >= 3 && !stopWords.contains($0) }
    }

    /// Naive: "cameras" → "camera", "glass" stays.
    static func singular(_ word: String) -> String {
        word.count > 3 && word.hasSuffix("s") && !word.hasSuffix("ss") ? String(word.dropLast()) : word
    }

    /// What a candidate shows, as words: its name, its tags, and the keywords it speaks.
    static func tokens(of clip: ClipInput) -> Set<String> {
        var words = tokens(clip.asset.name) + clip.asset.tags.flatMap(tokens)
        if clip.asset.info.hasAudio {
            words += (clip.analysis.keywords?.tags ?? []).filter { $0.kind != .emphasis }.flatMap { tokens($0.lemma) }
        }
        return Set(words)
    }

    /// 2 when `lemma` is one of `tokens`, 1 when a token of 5 or more letters begins it ("photo" in "photograph").
    static func strength(_ lemma: String, _ tokens: Set<String>) -> Double? {
        let word = singular(lemma.lowercased())
        if tokens.contains(word) { return 2 }
        return tokens.contains { $0.count >= 5 && word.hasPrefix($0) } ? 1 : nil
    }

    /// Cutaways over a `duration`-second timeline, at least `rule.minSpacing` apart (and never overlapping), at most
    /// `rule.maxPerMinute` in a minute, none over the title (the first 2.5 s), the last 1.5 s or a word of `keep`, so
    /// the speaker opens and closes the video. Each takes the best-matching candidate, favouring ones not shown yet,
    /// and plays on from where that candidate last stopped.
    static func place(_ candidates: [ClipInput], words: [TimedWord], keep: [TimedWord], rule: BRollRule, slot: Slot,
                      duration: Double, rate: FrameRate, ids: inout IDGenerator) -> Placement {
        let tokens = candidates.map(tokens(of:))
        var uses = [Int](repeating: 0, count: candidates.count)
        var cursor = candidates.map(\.range.lowerBound)
        var starts: [Double] = []
        var out = Placement()
        for w in words.sorted(by: { $0.start < $1.start }) where !w.isFiller {
            guard let lemma = w.lemma else { continue }
            let scored = candidates.indices.compactMap { i in
                strength(lemma, tokens[i]).map { (i, $0 + (uses[i] == 0 ? 0.5 : 0) - Double(uses[i])) }
            }
            guard let pick = scored.max(by: { $0.1 < $1.1 })?.0 else { continue }
            out.matched = true
            let clip = candidates[pick]
            let start = w.start - 0.15
            let length = min(rule.seconds, clip.range.upperBound - clip.range.lowerBound)
            guard start >= 2.5, start + length <= duration - 1.5, length > 0,
                  start - (starts.last ?? -.infinity) >= max(rule.minSpacing, rule.seconds),
                  starts.count(where: { Int($0 / 60) == Int(start / 60) }) < rule.maxPerMinute,
                  !keep.contains(where: { $0.start < start + length && $0.end > start }) else { continue }
            if cursor[pick] + length > clip.range.upperBound + 1e-6 { cursor[pick] = clip.range.lowerBound }
            let range = TimeRange(start: .frames(start, rate), end: .frames(start + length, rate))
            guard range.duration > .zero else { continue }
            let source = TimeRange(start: RationalTime(seconds: cursor[pick]), duration: range.duration)
            var item = Item(id: ids.uuid(), name: clip.asset.name, range: range,
                            content: .media(MediaRef(asset: clip.asset.id, source: source, useAudio: false)),
                            transform: slot.transform, fadeIn: .frames(0.1, rate), fadeOut: .frames(0.15, rate),
                            origin: .auto(pass: "broll"), slot: slot.id)
            item.content = DraftPipeline.clampSource(item.content, to: clip.asset.info.duration)
            out.items.append(item)
            if !out.used.contains(clip.asset.name) { out.used.append(clip.asset.name) }
            cursor[pick] += length
            uses[pick] += 1
            starts.append(start)
        }
        return out
    }
}

extension MediaAsset {
    /// Video the user marked as B-roll, by a "b-roll" or "broll" tag or name, which drafts may cut away to unasked.
    public var isBRoll: Bool {
        func marked(_ text: String) -> Bool {
            let words = text.lowercased().split { !$0.isLetter }
            return words.contains("broll") || zip(words, words.dropFirst()).contains { $0 == "b" && $1 == "roll" }
        }
        return info.hasVideo && (marked(name) || tags.contains(where: marked))
    }
}
