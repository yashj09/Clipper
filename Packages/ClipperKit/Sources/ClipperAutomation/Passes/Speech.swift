import ClipperCore
import Foundation

/// What a word contributes to emphasis. Decided once per word in `SpeechPlan`; captions and zooms read two views.
struct Cue: OptionSet, Sendable, Hashable {
    let rawValue: UInt8
    /// Has a digit, or is a number word ("three", "million").
    static let number = Cue(rawValue: 1 << 0)
    static let exclaim = Cue(rawValue: 1 << 1)
    /// ALL CAPS, two or more letters.
    static let caps = Cue(rawValue: 1 << 2)
    /// Mean level over the word at least 4 dB above the median word nearby.
    static let loud = Cue(rawValue: 1 << 3)
    /// First word of a sentence that ends in "?".
    static let question = Cue(rawValue: 1 << 4)
    /// First word of a sentence after at least 0.6 s of source silence.
    static let afterPause = Cue(rawValue: 1 << 5)
    /// Emphasis already decided (the user's, on a caption being re-paged).
    static let marked = Cue(rawValue: 1 << 6)

    /// Caption highlight: word-level salience only. A highlighted "So" at every sentence start would be noise.
    var highlights: Bool { !isDisjoint(with: [.number, .exclaim, .caps, .loud, .marked]) }
    /// Zoom candidate: any cue, so every highlighted word can carry a zoom.
    var zooms: Bool { !isEmpty }
}

/// A transcript word with its cue. Reads like a `TranscriptWord` (`w.start`, `w.isFiller`).
@dynamicMemberLookup
struct SpokenWord: Equatable {
    var word: TranscriptWord
    var cue: Cue
    subscript<T>(dynamicMember path: KeyPath<TranscriptWord, T>) -> T { word[keyPath: path] }
}

/// Everything the draft decides about one clip's speech, in source seconds. A pure function of the clip and the rule.
struct SpeechPlan: Equatable {
    /// Words in the clip range that survive the plan, with cues. Fillers stay: filler policy is the cutter's.
    var words: [SpokenWord]
    /// Source time the cutter must drop.
    var excluded: RangeSet<Double>
    var removedRestarts: Int

    /// `rule == nil` excludes nothing; cues are still computed, since captions and zooms want them either way.
    init(clip: ClipInput, rule: SpeechEditRule?) {
        let range = clip.range
        let transcript = clip.analysis.transcript
        let all = (transcript?.words ?? []).filter { $0.end > range.lowerBound && $0.start < range.upperBound }
        let english = transcript.map { Locale.Language(identifier: $0.locale).languageCode == .english } ?? false
        let drops = rule?.falseStarts == true ? Speech.restarts(all, english: english) : []
        var excluded = RangeSet<Double>()
        var dropped = IndexSet()
        for span in drops {
            excluded.insert(contentsOf: Speech.cut(all, dropping: span, clipEnd: range.upperBound))
            dropped.insert(integersIn: span.lowerBound...span.upperBound)
        }
        let left = all.indices.filter { !dropped.contains($0) }.map { all[$0] }
        let cues = Speech.cues(left, sentences: Speech.sentences(left), speech: clip.analysis.speech, english: english)
        words = zip(left, cues).map { SpokenWord(word: $0, cue: $1) }
        self.excluded = excluded
        removedRestarts = drops.count
    }
}

enum Speech {
    struct Sentence {
        var start: Double
        var end: Double
        var words: [TranscriptWord]
        /// Positions of `words` in the array that was split.
        var indices: Range<Int>
        var pauseBefore: Double
        var pauseAfter: Double
    }

    /// Splits words into sentences at end punctuation or at a pause longer than `maxGap`.
    static func sentences(_ words: [TranscriptWord], maxGap: Double = 0.8) -> [Sentence] {
        var out: [Sentence] = []
        var first = 0
        for (i, w) in words.enumerated() {
            let next = i + 1 < words.count ? words[i + 1] : nil
            let gap = next.map { $0.start - w.end } ?? .infinity
            if w.text.last.map({ ".?!".contains($0) }) == true || gap > maxGap || next == nil {
                out.append(Sentence(start: words[first].start, end: w.end, words: Array(words[first...i]), indices: first..<(i + 1),
                                    pauseBefore: 0, pauseAfter: gap))
                first = i + 1
            }
        }
        for i in out.indices { out[i].pauseBefore = i == 0 ? .infinity : out[i].start - out[i - 1].end }
        return out
    }

    /// Lowercased, with leading and trailing punctuation removed: the form repeats are compared in.
    static func norm(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.symbols).union(.whitespaces))
    }

    static func endsSentence(_ text: String) -> Bool { text.last.map { ".?!".contains($0) } ?? false }

    /// Short words people stutter on. A doubled word outside this list is usually meant ("go go go").
    static let functionWords: Set<String> = [
        "i", "i'm", "i've", "the", "a", "an", "and", "so", "we", "it", "it's", "to", "of", "in", "on", "at", "but", "you",
        "my", "this", "for", "with", "if", "or", "he", "she", "they", "there", "what", "when", "because", "like",
    ]
    /// Doubles that are grammatical or deliberate: "very very good", "I knew that that was it", "what it is is".
    static let keepDoubles: Set<String> = ["very", "really", "so", "no", "yes", "much", "more", "that", "had", "is", "bye", "too"]

    /// Word-index spans of stutters and restarts to drop. The later occurrence is always the one kept. Fillers
    /// between a fragment and its restart ("I, um, I think") go with the fragment. Single-word stutters need the
    /// English lexicons; repeats of two or more words work in any language.
    static func restarts(_ words: [TranscriptWord], english: Bool) -> [ClosedRange<Int>] {
        let n = words.indices.filter { !words[$0].isFiller }
        let key = n.map { norm(words[$0].text) }
        var spans: [ClosedRange<Int>] = []
        var i = 0
        while i < n.count {
            var matched = 0
            for k in (1...4).reversed() where i + k < n.count {
                let f = i..<(i + k)
                let lastF = words[n[i + k - 1]], firstR = words[n[i + k]]
                guard firstR.start - lastF.end < 1.0, !f.contains(where: { endsSentence(words[n[$0]].text) }) else { continue }
                let r = (i + k)..<min(n.count, i + 2 * k)
                let p = zip(f, r).prefix { key[$0] == key[$1] }.count
                let exact = p == k
                var partial = false
                if p >= 2, p < k {
                    // A restart re-says what the fragment was reaching for: "so the thing, so the main thing".
                    // "I like cats, I like dogs" keeps its tail word out of the restart and stays.
                    let tail = key[(i + p)..<(i + k)]
                    let ahead = Set(key[min(n.count, i + k + p)..<min(n.count, i + 2 * k + 2)])
                    let breakAfter = ",-–—".contains(lastF.text.last ?? " ") || n[i + k] - n[i + k - 1] > 1
                        || firstR.start - lastF.end >= 0.25
                    partial = breakAfter && tail.allSatisfy(ahead.contains)
                }
                if k == 1, exact, !(english && functionWords.contains(key[i]) && !keepDoubles.contains(key[i])) { continue }
                if exact || partial { matched = k; break }
            }
            if matched > 0 {
                spans.append(n[i]...(n[i + matched] - 1))
                i += matched
            } else {
                i += 1
            }
        }
        return spans
    }

    /// The source range that removes `words[span]`: from its first word's start to just before the next word,
    /// so the pause and a late-ending ASR word's tail go too. 0.08 s is the silence cut's default lead-in.
    static func cut(_ words: [TranscriptWord], dropping span: ClosedRange<Int>, clipEnd: Double) -> Range<Double> {
        let next = span.upperBound + 1 < words.count ? words[span.upperBound + 1].start : clipEnd
        let start = words[span.lowerBound].start
        return start..<max(words[span.upperBound].end, next - 0.08, start)
    }

    static let numberWords: Set<String> = [
        "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "twenty", "thirty",
        "forty", "fifty", "hundred", "thousand", "million", "billion", "percent",
    ]

    /// One cue per word. Text cues need only the word, `loud` needs `speech`, structure cues need `sentences`.
    static func cues(_ words: [TranscriptWord], sentences: [Sentence], speech: SpeechActivity?, english: Bool) -> [Cue] {
        var cues = words.map { w -> Cue in
            guard !w.isFiller else { return [] }
            var c: Cue = []
            let letters = w.text.filter(\.isLetter)
            if w.text.contains(where: \.isNumber) || (english && numberWords.contains(norm(w.text))) { c.insert(.number) }
            if w.text.hasSuffix("!") { c.insert(.exclaim) }
            if letters.count >= 2, letters == letters.uppercased() { c.insert(.caps) }
            return c
        }
        if let speech {
            for i in loudWords(words, speech: speech) { cues[i].insert(.loud) }
        }
        for s in sentences {
            guard let first = s.indices.first(where: { !words[$0].isFiller }) else { continue }
            if s.words.last.map({ $0.text.hasSuffix("?") }) == true { cues[first].insert(.question) }
            if s.pauseBefore >= 0.6 { cues[first].insert(.afterPause) }
        }
        return cues
    }

    /// Indices of words whose mean level is at least 4 dB above the median word within 10 s, and above the voice
    /// threshold. Per word, not per frame, so pauses don't drag the reference down.
    static func loudWords(_ words: [TranscriptWord], speech: SpeechActivity) -> [Int] {
        let rms = speech.rms
        guard rms.hop > 0 else { return [] }
        let level: [Float?] = words.map { w in
            guard !w.isFiller else { return nil }
            let lo = max(0, Int((w.start / rms.hop).rounded(.up))), hi = min(rms.values.count, Int((w.end / rms.hop).rounded(.down)))
            guard hi > lo else { return nil }
            return rms.values[lo..<hi].reduce(0, +) / Float(hi - lo)
        }
        let mids = words.map { ($0.start + $0.end) / 2 }
        var out: [Int] = []
        var a = 0, b = 0
        for i in words.indices {
            guard let m = level[i] else { continue }
            while mids[a] < mids[i] - 10 { a += 1 }
            while b < words.count, mids[b] <= mids[i] + 10 { b += 1 }
            let near = level[a..<b].compactMap { $0 }.sorted()
            if m - near[near.count / 2] >= 4, m > speech.threshold { out.append(i) }
        }
        return out
    }
}
