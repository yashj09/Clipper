import ClipperCore
import CryptoKit
import Foundation
import NaturalLanguage
import Translation

public enum CaptionTranslationError: Error, LocalizedError, Equatable {
    case noCaptionTrack
    case trackNotFound(TrackID)
    case notACaptionTrack(TrackID)
    case sameLanguage(String)
    /// The pair is supported but its on-device model isn't downloaded.
    case pairNotInstalled(source: String, target: String)
    case unsupportedPair(source: String, target: String)

    public var errorDescription: String? {
        switch self {
        case .noCaptionTrack: "The timeline has no caption track to translate."
        case .trackNotFound: "The caption track to translate is no longer in the timeline."
        case .notACaptionTrack: "Only caption tracks can be translated."
        case .sameLanguage(let tag): "The captions are already in \(Self.name(tag))."
        case .pairNotInstalled(let s, let t):
            "On-device translation from \(Self.name(s)) to \(Self.name(t)) isn't installed. Download it in System Settings ▸ "
                + "General ▸ Language & Region ▸ Translation Languages, or accept Clipper's offer to download it, then try again."
        case .unsupportedPair(let s, let t):
            "Apple's on-device translation doesn't support \(Self.name(s)) to \(Self.name(t))."
        }
    }

    static func name(_ tag: String) -> String {
        Locale.current.localizedString(forIdentifier: tag).map { "\($0) (\(tag))" } ?? tag
    }
}

/// Adds translated caption tracks with Apple's on-device Translation framework (no network, no downloads triggered).
///
/// Each caption page is translated as a whole (one batch request for the track). Translated words can't be aligned to
/// the audio, so they are spread over the time the source page's words span, proportionally to their length: the
/// active-word highlight still moves through the page and the page timing itself is unchanged.
///
/// Languages written without spaces (Chinese, Japanese, Thai…): the text renderer wraps on word boundaries and puts a
/// space between words, so single characters would be spaced out and a whole page as one word would never wrap.
/// Instead the translation is cut into short phrases — at punctuation, and at most `unspacedChunk` characters — that
/// wrap and highlight like words. Subtitle sidecars join them back without spaces.
/// Right-to-left languages are split on spaces like any other; the renderer lays such pages out right to left.
public struct CaptionTranslator: Sendable {
    public var source: Locale.Language

    /// Longest "word" for languages without word spaces.
    static let unspacedChunk = 8
    /// Origin of translated items; marks translated tracks for replacement.
    static let pass = "translation"

    /// - Parameter source: language of the captions when the caption track has no `language` of its own.
    public init(source: Locale.Language = Locale.Language(identifier: "en")) { self.source = source }

    /// For each target: `.installed` (translate now), `.supported` (needs a download first) or `.unsupported`.
    public static func availability(from source: Locale.Language, to targets: [Locale.Language]) async -> [Locale.Language: LanguageAvailability.Status] {
        let availability = LanguageAvailability()
        var out: [Locale.Language: LanguageAvailability.Status] = [:]
        for target in targets { out[target] = await availability.status(from: source, to: target) }
        return out
    }

    /// Adds a caption track translated to `target`, right after the source caption track, hidden, named e.g.
    /// "Captions (es)" and tagged with the language. Calling it again for the same language replaces that track
    /// (item and track IDs are derived from the source IDs + language, so re-runs are stable).
    ///
    /// - Parameter sourceTrack: the caption track to translate; nil = the first caption track.
    /// - Throws: `CaptionTranslationError.pairNotInstalled` when the language pair hasn't been downloaded.
    public func addTranslatedTrack(to timeline: Timeline, target: Locale.Language, sourceTrack: TrackID? = nil) async throws -> Timeline {
        let track = try Self.sourceTrack(in: timeline, sourceTrack)
        let from = track.language.map { Locale.Language(identifier: $0) } ?? source
        let fromTag = Self.tag(from), toTag = Self.tag(target)
        guard fromTag != toTag else { throw CaptionTranslationError.sameLanguage(toTag) }

        switch await LanguageAvailability().status(from: from, to: target) {
        case .installed: break
        case .supported: throw CaptionTranslationError.pairNotInstalled(source: fromTag, target: toTag)
        case .unsupported: throw CaptionTranslationError.unsupportedPair(source: fromTag, target: toTag)
        @unknown default: throw CaptionTranslationError.unsupportedPair(source: fromTag, target: toTag)
        }

        // Translate whole sentences (pages are only 2–7 words; translated alone they lose context), then spread each
        // sentence's translation back over its pages in proportion to their source word counts.
        let pages = Self.pages(of: track, language: fromTag)
        let groups = Self.sentenceGroups(track)
        var translations: [ItemID: String] = [:]
        if !groups.isEmpty {
            let pageText = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0.text) })
            let session = TranslationSession(installedSource: from, target: target)
            let requests = groups.enumerated().map { i, group in
                TranslationSession.Request(sourceText: CaptionLanguage.join(group.compactMap { pageText[$0.id] }, language: fromTag),
                                           clientIdentifier: String(i))
            }
            let responses: [TranslationSession.Response]
            do {
                responses = try await session.translations(from: requests)
            } catch TranslationError.notInstalled {
                throw CaptionTranslationError.pairNotInstalled(source: fromTag, target: toTag)
            }
            for (n, response) in responses.enumerated() {
                let i = response.clientIdentifier.flatMap(Int.init) ?? n
                guard groups.indices.contains(i) else { continue }
                let group = groups[i]
                let words = Self.split(response.targetText, language: toTag, uppercase: false)
                for (page, share) in zip(group, Self.distribute(words, over: group.map(\.words))) where !share.isEmpty {
                    translations[page.id] = CaptionLanguage.join(share, language: toTag)
                }
            }
        }
        return try Self.applying(translations, to: timeline, sourceTrack: track.id, language: toTag)
    }

    // MARK: - Pure parts

    /// BCP-47 tag used for `Track.language` and sidecar names ("es", "zh-Hant", "pt-PT").
    static func tag(_ language: Locale.Language) -> String { language.minimalIdentifier }

    static func sourceTrack(in timeline: Timeline, _ id: TrackID?) throws -> Track {
        if let id {
            guard let track = timeline.tracks.first(where: { $0.id == id }) else { throw CaptionTranslationError.trackNotFound(id) }
            guard track.kind == .caption else { throw CaptionTranslationError.notACaptionTrack(id) }
            return track
        }
        // Translations are inserted after their source, so the first caption track is the original.
        guard let track = timeline.tracks.first(where: { $0.kind == .caption }) else { throw CaptionTranslationError.noCaptionTrack }
        return track
    }

    /// Consecutive caption pages forming a sentence: a group ends after sentence punctuation, before a pause of more
    /// than 0.8 s, or at about 25 source words.
    static func sentenceGroups(_ track: Track) -> [[(id: ItemID, words: Int)]] {
        var groups: [[(id: ItemID, words: Int)]] = []
        var current: [(id: ItemID, words: Int)] = []
        var lastEnd: RationalTime?
        for item in track.items {
            guard case .caption(let c) = item.content, !c.words.isEmpty else { continue }
            if let lastEnd, (item.start - lastEnd).seconds > 0.8, !current.isEmpty { groups.append(current); current = [] }
            current.append((item.id, c.words.count))
            lastEnd = item.end
            let ends = c.words.last?.text.last.map { ".?!。？！".contains($0) } ?? false
            if ends || current.reduce(0, { $0 + $1.words }) >= 25 { groups.append(current); current = [] }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    /// Splits `words` into consecutive runs sized in proportion to `weights` (largest remainder), giving every run at
    /// least one word when there are enough words. Order is preserved; all words are used.
    static func distribute(_ words: [String], over weights: [Int]) -> [[String]] {
        guard !weights.isEmpty else { return [] }
        guard !words.isEmpty else { return weights.map { _ in [] } }
        let n = words.count, total = max(1, weights.reduce(0) { $0 + max($1, 1) })
        let exact = weights.map { Double(max($0, 1)) * Double(n) / Double(total) }
        var counts = exact.map { Int($0.rounded(.down)) }
        let order = exact.indices.sorted { (exact[$0] - Double(counts[$0])) > (exact[$1] - Double(counts[$1])) }
        for i in order.prefix(n - counts.reduce(0, +)) { counts[i] += 1 }
        if n >= weights.count {
            // Make sure no page ends up empty: borrow from the largest run.
            for i in counts.indices where counts[i] == 0 {
                if let j = counts.indices.max(by: { counts[$0] < counts[$1] }), counts[j] > 1 { counts[j] -= 1; counts[i] = 1 }
            }
        }
        var out: [[String]] = [], k = 0
        for c in counts { out.append(Array(words[k..<min(n, k + c)])); k += c }
        return out
    }

    /// The text of each non-empty caption page, in order.
    static func pages(of track: Track, language: String) -> [(id: ItemID, text: String)] {
        track.items.compactMap { item in
            guard case .caption(let c) = item.content, !c.words.isEmpty else { return nil }
            return (item.id, CaptionLanguage.join(c.words.map(\.text), language: language))
        }
    }

    /// Builds the translated track from page translations (keyed by source item ID) and inserts it after the source,
    /// replacing an earlier translation of that track into the same language. Pages without a translation are skipped.
    static func applying(_ translations: [ItemID: String], to timeline: Timeline, sourceTrack: TrackID, language: String) throws -> Timeline {
        var tl = timeline
        guard let source = tl.tracks.first(where: { $0.id == sourceTrack }) else { throw CaptionTranslationError.trackNotFound(sourceTrack) }
        let trackID = derivedID(source.id, language)
        let derivedItems = Set(source.items.map { derivedID($0.id, language) })
        func isPrevious(_ t: Track) -> Bool {
            t.id != source.id && t.kind == .caption
                && (t.id == trackID || (t.language == language && !t.items.isEmpty && t.items.allSatisfy { derivedItems.contains($0.id) }))
        }
        let previous = tl.tracks.first(where: isPrevious)
        tl.tracks.removeAll(where: isPrevious)

        var items: [Item] = []
        for item in source.items {
            guard case .caption(let caption) = item.content, !caption.words.isEmpty, let text = translations[item.id] else { continue }
            let words = split(text, language: language, uppercase: tl.styles[caption.style]?.uppercase ?? false)
            guard !words.isEmpty else { continue }
            let span = wordSpan(caption, duration: item.range.duration)
            let times = retime(weights: words.map(\.count), start: span.start, end: span.end)
            let emphasized = Set(caption.words.filter(\.emphasis).map { normalized($0.text) })
            let translated = zip(words, times).map { word, t in
                CaptionContent.Word(text: word, start: t.start, end: t.end,
                                    emphasis: word.contains { $0.isNumber } || emphasized.contains(normalized(word)))
            }
            var copy = item
            copy.id = derivedID(item.id, language)
            copy.content = .caption(CaptionContent(words: translated, style: caption.style))
            copy.origin = .auto(pass: pass)
            copy.locked = false
            items.append(copy)
        }
        let track = Track(id: trackID, kind: .caption, name: "\(source.name) (\(language))", items: items,
                          hidden: previous?.hidden ?? true, language: language)
        tl.tracks.insert(track, at: (tl.trackIndex(source.id) ?? tl.tracks.count - 1) + 1)
        return tl
    }

    /// Splits `count`-weighted words over [start, end]: each word gets a share proportional to its weight (minimum 1).
    /// Boundaries are exact integers at `RationalTime.defaultScale`, monotonic, the first at `start`, the last at `end`.
    static func retime(weights: [Int], start: RationalTime, end: RationalTime) -> [(start: RationalTime, end: RationalTime)] {
        guard !weights.isEmpty else { return [] }
        let scale = RationalTime.defaultScale
        let a = start.rescaled(to: scale).value, b = max(end.rescaled(to: scale).value, a)
        let w = weights.map { Int64(max($0, 1)) }
        let total = w.reduce(0, +)
        var out: [(start: RationalTime, end: RationalTime)] = []
        var cumulative: Int64 = 0, previous = a
        for (i, wi) in w.enumerated() {
            cumulative += wi
            let next = i == w.count - 1 ? b : a + (b - a) * cumulative / total
            out.append((RationalTime(value: previous, scale: scale), RationalTime(value: next, scale: scale)))
            previous = next
        }
        return out
    }

    /// Where the source page's words are spoken (item-relative), clamped to the item; the whole item if degenerate.
    static func wordSpan(_ caption: CaptionContent, duration: RationalTime) -> (start: RationalTime, end: RationalTime) {
        guard let first = caption.words.first?.start, let last = caption.words.map(\.end).max() else { return (.zero, duration) }
        let s = RationalTime.max(.zero, RationalTime.min(first, duration))
        let e = RationalTime.min(duration, last)
        return e > s ? (s, e) : (.zero, duration)
    }

    /// Translated page → caption words. Spaced languages split on whitespace; unspaced ones into short phrases.
    /// Uppercase styles drop trailing commas/periods, like the source captions.
    static func split(_ text: String, language: String, uppercase: Bool) -> [String] {
        var words = CaptionLanguage.usesWordSpaces(language)
            ? text.split(whereSeparator: \.isWhitespace).map(String.init)
            : chunks(text, max: unspacedChunk, language: language)
        if uppercase {
            words = words.map { w in
                var t = w
                while let last = t.last, ",.;:，。；：、".contains(last) { t.removeLast() }
                return t.isEmpty ? w : t
            }
        }
        return words
    }

    /// Phrases for unspaced scripts: clauses end after punctuation (kept attached, so "。" or "！" never stands alone)
    /// and at whitespace; a clause longer than `max` characters is cut into the fewest near-equal pieces that fit,
    /// moving each cut to the nearest word boundary found by `NLTokenizer` so words aren't split.
    static func chunks(_ text: String, max: Int, language: String? = nil) -> [String] {
        let chars = Array(text)
        var clauses: [[Character]] = [], current: [Character] = []
        for (i, ch) in chars.enumerated() {
            if ch.isWhitespace {
                if !current.isEmpty { clauses.append(current); current = [] }
                continue
            }
            current.append(ch)
            if ch.isPunctuation, !(i + 1 < chars.count && chars[i + 1].isPunctuation) { clauses.append(current); current = [] }
        }
        if !current.isEmpty { clauses.append(current) }

        return clauses.flatMap { clause -> [String] in
            let body = clause.count - clause.reversed().prefix { $0.isPunctuation }.count
            let pieces = (body + max - 1) / max
            guard pieces > 1 else { return [String(clause)] }
            let boundaries = wordBoundaries(String(clause[..<body]), language: language)
            var cuts = [0]
            for p in 1..<pieces {
                let ideal = Double(body * p) / Double(pieces)
                let candidates = boundaries.filter { $0 > cuts.last! && $0 < body }
                let nearest = candidates.min { abs(Double($0) - ideal) < abs(Double($1) - ideal) }
                let cut = nearest.flatMap { abs(Double($0) - ideal) <= Double(max) / 2 ? $0 : nil } ?? Int(ideal.rounded())
                if cut > cuts.last!, cut < body { cuts.append(cut) }
            }
            cuts.append(clause.count)
            return zip(cuts, cuts.dropFirst()).map { String(clause[$0..<$1]) }
        }
    }

    /// Character offsets where words start or end in `text` (unspaced scripts need a dictionary-based tokenizer).
    static func wordBoundaries(_ text: String, language: String?) -> Set<Int> {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        if let language { tokenizer.setLanguage(nlLanguage(language)) }
        var out = Set<Int>()
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            out.insert(text.distance(from: text.startIndex, to: range.lowerBound))
            out.insert(text.distance(from: text.startIndex, to: range.upperBound))
            return true
        }
        return out
    }

    /// NaturalLanguage wants a script for Chinese ("zh" alone isn't one of its languages).
    static func nlLanguage(_ tag: String) -> NLLanguage {
        guard CaptionLanguage.base(tag) == "zh" else { return NLLanguage(rawValue: CaptionLanguage.base(tag)) }
        let traditional = ["Hant", "TW", "HK", "MO"].contains { tag.contains($0) }
        return traditional ? .traditionalChinese : .simplifiedChinese
    }

    static func normalized(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    }

    /// Stable UUID from a source ID and a language: SHA-256 → 16 bytes with RFC 9562 version 8 / variant bits.
    static func derivedID(_ id: UUID, _ language: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data("clipper.translation|\(id.uuidString)|\(language)".utf8)))
        var b = Array(digest.prefix(16))
        b[6] = (b[6] & 0x0F) | 0x80
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}
