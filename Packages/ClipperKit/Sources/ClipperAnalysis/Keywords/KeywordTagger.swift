import ClipperCore
import Foundation
import NaturalLanguage

/// Finds the words of a transcript worth calling out (numbers, names, content nouns, shouted words) with the
/// on-device NaturalLanguage tagger. Same transcript, same tags.
public enum KeywordTagger {
    /// Nouns too vague to call out, by lemma.
    static let stopNouns: Set<String> = [
        "thing", "stuff", "kind", "sort", "part", "someone", "something", "anything", "everything", "nothing",
        "everyone", "anyone", "somebody", "nobody", "people", "guy", "bunch", "point", "fact", "case", "yeah",
        "okay", "today", "lot", "way",
    ]

    static let nameKinds: [NLTag: KeywordTags.Kind] = [
        .personalName: .person, .placeName: .place, .organizationName: .organization,
    ]

    public static func tag(_ transcript: Transcript) -> KeywordTags {
        let words = transcript.words
        guard !words.isEmpty else { return KeywordTags(tags: []) }
        let text = words.map(\.text).joined(separator: " ")
        var starts: [Int] = []
        var offset = 0
        for w in words { starts.append(offset); offset += w.text.utf16.count + 1 }
        func wordIndices(_ range: Range<String.Index>) -> ClosedRange<Int> {
            let lo = range.lowerBound.utf16Offset(in: text), hi = range.upperBound.utf16Offset(in: text) - 1
            func index(_ o: Int) -> Int {
                var lo = 0, hi = starts.count - 1
                while lo < hi { let m = (lo + hi + 1) / 2; if starts[m] <= o { lo = m } else { hi = m - 1 } }
                return lo
            }
            return index(lo)...max(index(lo), index(hi))
        }

        let tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType, .lemma])
        tagger.string = text
        let all = text.startIndex..<text.endIndex
        if let code = Locale(identifier: transcript.locale).language.languageCode?.identifier {
            tagger.setLanguage(NLLanguage(rawValue: code), range: all)
        }
        var lexical = [NLTag?](repeating: nil, count: words.count)
        var names = [NLTag?](repeating: nil, count: words.count)
        var lemmas = [String?](repeating: nil, count: words.count)
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        // A word can hold several tokens ("don't", "$5"); its first token speaks for it.
        tagger.enumerateTags(in: all, unit: .word, scheme: .lexicalClass, options: options) { tag, range in
            let i = wordIndices(range).lowerBound
            if lexical[i] == nil { lexical[i] = tag }
            return true
        }
        tagger.enumerateTags(in: all, unit: .word, scheme: .lemma, options: options) { tag, range in
            let i = wordIndices(range).lowerBound
            if lemmas[i] == nil, let tag, !tag.rawValue.isEmpty { lemmas[i] = tag.rawValue }
            return true
        }
        tagger.enumerateTags(in: all, unit: .word, scheme: .nameType, options: options) { tag, range in
            guard let tag, nameKinds[tag] != nil else { return true }
            for i in wordIndices(range) where names[i] == nil { names[i] = tag }
            return true
        }

        var tags: [KeywordTags.Tag] = []
        for (i, w) in words.enumerated() where !w.isFiller {
            let bare = w.text.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            guard !bare.isEmpty else { continue }
            let lemma = (lemmas[i] ?? bare).lowercased()
            let emoji = KeywordEmoji.table[lemma]
            let kind: KeywordTags.Kind? =
                if bare.contains(where: \.isNumber) || lexical[i] == .number { .number }
                // Before names: the tagger reads a shouted "INSANE!" as an organization.
                else if w.text.hasSuffix("!") { .emphasis }
                else if let name = names[i].flatMap({ nameKinds[$0] }) { name }
                else if isShouted(w.text) { .emphasis }
                // Short nouns ("car", "dog") only when they have an emoji, else "bit", "end" and the like flood in.
                else if lexical[i] == .noun, !stopNouns.contains(lemma),
                        bare.count(where: \.isLetter) >= 4 || emoji != nil { .noun }
                else { nil }
            if let kind { tags.append(.init(word: i, kind: kind, lemma: lemma, emoji: emoji)) }
        }
        return KeywordTags(tags: tags)
    }

    /// ALL CAPS, as in the Captions pass's emphasis rule.
    static func isShouted(_ text: String) -> Bool {
        text.count(where: \.isLetter) >= 2 && text == text.uppercased()
    }
}
