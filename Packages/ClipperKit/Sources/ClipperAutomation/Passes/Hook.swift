import ClipperCore
import Foundation

enum Hook {
    struct ColdOpen: Equatable {
        /// The hook's segments first, then the rest in their order.
        var segments: [Segment]
        /// How many leading segments are the hook.
        var count: Int
        /// The hook sentence's words, fillers left out.
        var text: String
    }

    /// The first briefed clip's hook sentence moved to the front, once. Nil, and the draft left alone, when the
    /// sentence was cut, already opens the draft, runs longer than `rule.maxSeconds`, scores under
    /// `rule.minImportance`, or shares a segment with another sentence (too tight a pause to split at). A sped-up
    /// pause either side of the hook goes: with the hook gone, the two would play back to back at the jump.
    static func coldOpen(_ segments: [Segment], clips: [ClipInput], rule: HookRule) -> ColdOpen? {
        guard let clip = segments.lazy.map(\.clip).first(where: { clips[$0].analysis.brief?.hookSentence != nil }),
              let hook = clips[clip].analysis.brief?.hookSentence else { return nil }
        let segs = Cutting.splitAtSentences(segments)
        let speaksHook: (Segment) -> Bool = { s in s.clip == clip && s.words.contains { $0.sentence == hook } }
        let onlyHook: (Segment) -> Bool = { s in speaksHook(s) && s.words.allSatisfy { $0.sentence == hook } }
        guard let first = segs.firstIndex(where: speaksHook), let last = segs.lastIndex(where: speaksHook),
              first != segs.firstIndex(where: \.hasSpeech) else { return nil }
        let run = segs[first...last]
        guard run.allSatisfy({ onlyHook($0) || ($0.speed != 1 && $0.words.isEmpty) }),
              run.reduce(0, { $0 + $1.timelineDuration }) <= rule.maxSeconds,
              (segs[first].importance ?? 1) >= rule.minImportance else { return nil }
        let text = run.flatMap(\.words).filter { !$0.isFiller }
            .map { $0.cue.contains(.profane) ? Profanity.masked($0.text) : $0.text }.joined(separator: " ")
        let before = segs[..<first].dropLast(segs[first - 1].speed != 1 ? 1 : 0)
        let after = segs[(last + 1)...].dropFirst(last + 1 < segs.count && segs[last + 1].speed != 1 ? 1 : 0)
        return ColdOpen(segments: Array(run) + before + after, count: run.count, text: text)
    }

    /// `text` cut to `limit` characters at a word boundary, with an ellipsis when shortened.
    static func excerpt(_ text: String, limit: Int = 40) -> String {
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        let words = cut.split(separator: " ").dropLast()
        return (words.isEmpty ? String(cut) : words.joined(separator: " ")) + "…"
    }
}
