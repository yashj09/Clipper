import ClipperCore
import Foundation

/// What a word contributes to emphasis. Decided once per word in `SpeechPlan`; captions and zooms read two views.
struct Cue: OptionSet, Sendable, Hashable {
    let rawValue: UInt16
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
    /// A name, place, organization or number, or a noun with an emoji, from the keyword tags.
    static let keyword = Cue(rawValue: 1 << 7)
    /// Profanity, marked only under a `ProfanityRule`. Never emphasised: the word is silenced and masked.
    static let profane = Cue(rawValue: 1 << 8)

    /// Caption highlight: word-level salience only. A highlighted "So" at every sentence start would be noise.
    var highlights: Bool { !contains(.profane) && !isDisjoint(with: [.number, .exclaim, .caps, .loud, .marked, .keyword]) }
    /// Zoom candidate: any cue but `keyword`. Keywords get callouts; zooming on each as well would be too busy.
    var zooms: Bool { !contains(.profane) && !subtracting(.keyword).isEmpty }
}

/// A transcript word with its cue. Reads like a `TranscriptWord` (`w.start`, `w.isFiller`).
@dynamicMemberLookup
struct SpokenWord: Equatable {
    var word: TranscriptWord
    var cue: Cue
    /// Index into `Transcript.sentences` of the clip's whole transcript, the numbering the LLM brief uses.
    var sentence: Int = 0
    /// The brief's score for `sentence`; nil without a brief that scores every sentence.
    var importance: Double?
    /// From the keyword tags.
    var emoji: String?
    /// The keyword tag's dictionary form, for any tag but `emphasis`; what B-roll matches clip names against.
    var lemma: String?
    subscript<T>(dynamicMember path: KeyPath<TranscriptWord, T>) -> T { word[keyPath: path] }
}

/// One line recorded several times. Takes are word positions in speaking order; `kept` indexes `takes`.
struct TakeGroup: Equatable {
    var takes: [Range<Int>]
    var kept: Int
    /// Everything in the group's span except the kept take, chatter between takes included.
    var dropped: [ClosedRange<Int>] {
        let keep = takes[kept]
        var out: [ClosedRange<Int>] = []
        if keep.lowerBound > takes[0].lowerBound { out.append(takes[0].lowerBound...(keep.lowerBound - 1)) }
        if keep.upperBound < takes[takes.count - 1].upperBound { out.append(keep.upperBound...(takes[takes.count - 1].upperBound - 1)) }
        return out
    }
}

/// A removed retake group as the draft reports it, in source seconds.
struct Retake: Equatable {
    var kept: Range<Double>
    /// 0-based position of the kept take among `takes`.
    var take: Int
    var takes: Int
    var removed: [Range<Double>]
}

/// Everything the draft decides about one clip's speech, in source seconds. A pure function of the clip and the rule.
struct SpeechPlan: Equatable {
    /// Words in the clip range that survive the plan, with cues. Fillers stay: filler policy is the cutter's.
    var words: [SpokenWord]
    /// Source time the cutter must drop.
    var excluded: RangeSet<Double>
    var retakes: [Retake]
    var removedRestarts: Int
    var removedTakes: Int { retakes.reduce(0) { $0 + $1.takes - 1 } }

    /// `rule == nil` excludes nothing; cues are still computed, since captions and zooms want them either way.
    /// Restarts go first so a stutter doesn't lower the similarity of two takes.
    init(clip: ClipInput, rule: SpeechEditRule?) {
        let range = clip.range
        let transcript = clip.analysis.transcript
        let every = transcript?.words ?? []
        let inClip = every.indices.filter { every[$0].end > range.lowerBound && every[$0].start < range.upperBound }
        let all = inClip.map { every[$0] }
        var sentenceOf = [Int](repeating: 0, count: every.count)
        let sentenceRanges = Transcript.sentences(every)
        for (s, r) in sentenceRanges.enumerated() { for i in r { sentenceOf[i] = s } }
        let scores = clip.analysis.brief.flatMap { $0.sentenceImportance.count == sentenceRanges.count ? $0.sentenceImportance : nil }
        let tags = Dictionary((clip.analysis.keywords?.tags ?? []).map { ($0.word, $0) }, uniquingKeysWith: { a, _ in a })
        let english = transcript.map { Locale.Language(identifier: $0.locale).languageCode == .english } ?? false
        let drops = rule?.falseStarts == true ? Speech.restarts(all, english: english) : []
        var excluded = RangeSet<Double>()
        var dropped = IndexSet()
        for span in drops {
            excluded.insert(contentsOf: Speech.cut(all, dropping: span, clipEnd: range.upperBound))
            dropped.insert(integersIn: span.lowerBound...span.upperBound)
        }
        let survivors = all.indices.filter { !dropped.contains($0) }
        let left = survivors.map { all[$0] }
        let sentences = Speech.sentences(left)
        let groups = rule?.takes.map { Speech.takeGroups(left, sentences: sentences, policy: $0) } ?? []
        var retaken = IndexSet()
        retakes = groups.map { g in
            let cuts = g.dropped.map { span in
                retaken.insert(integersIn: span.lowerBound...span.upperBound)
                return Speech.cut(left, dropping: span, clipEnd: range.upperBound)
            }
            for c in cuts { excluded.insert(contentsOf: c) }
            let keep = g.takes[g.kept]
            return Retake(kept: left[keep.lowerBound].start..<left[keep.upperBound - 1].end, take: g.kept, takes: g.takes.count, removed: cuts)
        }
        let cues = Speech.cues(left, sentences: sentences, speech: clip.analysis.speech, english: english)
        words = left.indices.filter { !retaken.contains($0) }.map { i in
            let index = inClip[survivors[i]]
            let tag = left[i].isFiller ? nil : tags[index]
            var cue = cues[i]
            if let tag, tag.kind != .emphasis, tag.kind != .noun || tag.emoji != nil { cue.insert(.keyword) }
            return SpokenWord(word: left[i], cue: cue, sentence: sentenceOf[index], importance: scores?[sentenceOf[index]], emoji: tag?.emoji,
                              lemma: tag.flatMap { $0.kind == .emphasis ? nil : $0.lemma })
        }
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

    /// Splits words into sentences at end punctuation (`Transcript.endsSentence`) or at a pause longer than `maxGap`.
    static func sentences(_ words: [TranscriptWord], maxGap: Double = 0.8) -> [Sentence] {
        var out: [Sentence] = []
        var first = 0
        for (i, w) in words.enumerated() {
            let next = i + 1 < words.count ? words[i + 1] : nil
            let gap = next.map { $0.start - w.end } ?? .infinity
            if Transcript.endsSentence(w.text, next: next?.text) || gap > maxGap || next == nil {
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

    static func endsSentence(_ text: String) -> Bool { Transcript.endsSentence(text) }

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

    /// Retake groups among the sentences of one clip. A sentence joins the latest group whose last or longest take
    /// it resembles: word bigrams overlapping by at least 0.6 of the shorter take (and at least two), no more than
    /// 90 s after the group's last take, with at most two sentences and twelve words between ("ugh, let me do that
    /// again"). Real content between two similar lines makes the second a callback, not a retake. Takes under half
    /// the length of the one they are compared with never join: a short fragment is a restart, not a take.
    static func takeGroups(_ words: [TranscriptWord], sentences: [Sentence], policy: TakePolicy) -> [TakeGroup] {
        let tokens = sentences.map { s in s.words.filter { !$0.isFiller }.map { norm($0.text) } }
        let bigrams = tokens.map { t in Set(zip(t, t.dropFirst()).map { "\($0) \($1)" }) }
        func alike(_ a: Int, _ b: Int) -> Bool {
            let shared = bigrams[a].intersection(bigrams[b]).count
            let shorter = min(tokens[a].count, tokens[b].count), longer = max(tokens[a].count, tokens[b].count)
            return shared >= 2 && Double(shorter) >= 0.5 * Double(longer)
                && Double(shared) >= 0.6 * Double(min(bigrams[a].count, bigrams[b].count))
        }
        var groups: [[Int]] = []
        for j in sentences.indices where bigrams[j].count >= 2 {
            let target = groups.indices.last { g in
                let last = groups[g][groups[g].count - 1]
                let between = (last + 1)..<j
                guard sentences[j].start - sentences[last].end <= 90, between.count <= 2,
                      between.reduce(0, { $0 + tokens[$1].count }) <= 12 else { return false }
                let longest = groups[g].max { tokens[$0].count < tokens[$1].count }!
                return alike(last, j) || alike(longest, j)
            }
            if let g = target { groups[g].append(j) } else { groups.append([j]) }
        }
        return groups.filter { $0.count >= 2 }.map { members in
            let length = members.map { tokens[$0].count }
            // An abandoned half-take never wins.
            let complete = members.indices.filter { Double(length[$0]) >= 0.8 * Double(length.max()!) }
            let kept = switch policy {
            case .last: complete.last!
            case .best: complete.max { (quality(sentences[members[$0]]), $0) < (quality(sentences[members[$1]]), $1) }!
            }
            return TakeGroup(takes: members.map { sentences[$0].indices }, kept: kept)
        }
    }

    /// Mean confidence (missing counts as 1), less the filler rate and the unevenness of the pace.
    static func quality(_ s: Sentence) -> Double {
        let spoken = s.words.filter { !$0.isFiller }
        let confidence = spoken.isEmpty ? 0 : spoken.reduce(0) { $0 + ($1.confidence ?? 1) } / Double(spoken.count)
        let fillerRate = Double(s.words.count - spoken.count) / Double(max(s.words.count, 1))
        let gaps = zip(s.words, s.words.dropFirst()).map { $1.start - $0.start }
        var paceCV = 0.0
        if gaps.count >= 2 {
            let mean = gaps.reduce(0, +) / Double(gaps.count)
            let sd = (gaps.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(gaps.count)).squareRoot()
            paceCV = mean > 0 ? sd / mean : 0
        }
        return confidence - 0.5 * fillerRate - 0.3 * paceCV
    }

    /// One marker per retake group, at the kept take's place on the timeline (or the next placed source time of that
    /// clip, if the duration fit dropped it), naming the removed source ranges so the user can find them.
    static func takeMarkers(_ plans: [Int: SpeechPlan], clips: [ClipInput], items: [Item], rate: FrameRate,
                            ids: inout IDGenerator) -> [Marker] {
        var found: [(time: RationalTime, name: String)] = []
        for (i, plan) in plans.sorted(by: { $0.key < $1.key }) {
            let clip = clips[i]
            for r in plan.retakes {
                let t = r.kept.lowerBound
                // The earliest source, not the earliest on the timeline: a cold open plays a later line first.
                guard let item = items.filter({ $0.content.mediaRef.map { $0.asset == clip.asset.id && $0.source.end.seconds > t } ?? false })
                    .min(by: { $0.content.mediaRef!.source.start < $1.content.mediaRef!.source.start }),
                      let ref = item.content.mediaRef else { continue }
                let removed = r.removed.map { "\(clock($0.lowerBound))–\(clock($0.upperBound))" }.joined(separator: ", ")
                found.append((RationalTime.frames(item.start.seconds + max(0, t - ref.source.start.seconds), rate),
                              "Retake: kept take \(r.take + 1) of \(r.takes) · removed \(removed) (\(clip.asset.name))"))
            }
        }
        return found.sorted { $0.time < $1.time }.map { Marker(id: ids.uuid(), time: $0.time, name: $0.name, origin: .auto(pass: "markers")) }
    }

    /// One marker per chapter of each speech clip's brief, where the chapter's first moment plays on the timeline.
    /// A chapter starts at its first word's transcribed start, which runs early, so a start up to a second before kept
    /// footage marks where that footage begins. Chapters that start further into cut material, or within 3 s of the
    /// chapter marker before, get none. `items` are the body of the video, without a cold open: a chapter that starts
    /// inside the hook sentence (`hook`, source seconds of one clip) is marked where its body goes on after the jump.
    static func chapterMarkers(_ plans: [Int: SpeechPlan], clips: [ClipInput], items: [Item], rate: FrameRate,
                               hook: (clip: Int, source: ClosedRange<Double>)? = nil) -> [(time: RationalTime, name: String)] {
        var found: [(time: RationalTime, name: String)] = []
        for i in plans.keys.sorted() {
            let clip = clips[i]
            for chapter in clip.analysis.brief?.chapters ?? [] {
                var t = chapter.start, slack = 1.0
                // The body goes on at the first kept footage after the hook, however long the pause there was.
                if let hook, hook.clip == i, hook.source.contains(t) { t = hook.source.upperBound; slack = .infinity }
                guard let item = items.filter({ $0.content.mediaRef.map { $0.asset == clip.asset.id && $0.source.end.seconds > t } ?? false })
                    .min(by: { $0.content.mediaRef!.source.start < $1.content.mediaRef!.source.start }),
                      let ref = item.content.mediaRef, ref.source.start.seconds - t <= slack else { continue }
                let offset = max(0, t - ref.source.start.seconds) / ref.speed
                found.append((RationalTime.frames(item.start.seconds + offset, rate), "Chapter: \(chapter.title)"))
            }
        }
        var kept: [(time: RationalTime, name: String)] = []
        for m in found.sorted(by: { $0.time < $1.time }) where kept.last.map({ (m.time - $0.time).seconds >= 3 }) ?? true { kept.append(m) }
        return kept
    }

    /// Words on the timeline with their cues, from each primary item's segment, at the item's playback speed.
    static func timedWords(_ items: [Item], segments: [ItemID: Segment]) -> [TimedWord] {
        var out: [TimedWord] = []
        for item in items {
            guard let seg = segments[item.id], let ref = item.content.mediaRef else { continue }
            let a = ref.source.start.seconds, b = ref.source.end.seconds
            func timeline(_ source: Double) -> Double { item.start.seconds + (source - a) / ref.speed }
            for w in seg.words where w.start >= a - 0.02 && w.end <= b + 0.02 {
                out.append(TimedWord(text: w.text, start: max(timeline(w.start), item.start.seconds),
                                     end: min(timeline(w.end), item.end.seconds), isFiller: w.isFiller, cue: w.cue, emoji: w.emoji, lemma: w.lemma))
            }
        }
        return out
    }

    static func clock(_ s: Double) -> String { String(format: "%d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60)) }

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
            // A loud "the" or "is" is delivery, not meaning; highlighting it reads as noise.
            for i in loudWords(words, speech: speech)
            where words[i].text.filter(\.isLetter).count >= 3 && !(english && functionWords.contains(norm(words[i].text))) {
                cues[i].insert(.loud)
            }
        }
        for s in sentences {
            guard let first = s.indices.first(where: { !words[$0].isFiller }) else { continue }
            if s.words.last.map({ $0.text.hasSuffix("?") }) == true { cues[first].insert(.question) }
            if s.pauseBefore.isFinite, s.pauseBefore >= 0.6 { cues[first].insert(.afterPause) }
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
