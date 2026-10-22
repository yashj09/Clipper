@testable import ClipperAnalysis
import ClipperCore
import Testing

private func transcript(_ text: String, locale: String = "en-US") -> Transcript {
    let words = text.split(separator: " ").enumerated().map { i, w in
        TranscriptWord(text: String(w), start: Double(i) * 0.4, end: Double(i) * 0.4 + 0.3)
    }
    return Transcript(locale: locale, engine: "test", words: Fillers.markFillers(words))
}

@Suite struct KeywordTaggerTests {
    @Test func tagsNumbersNamesNounsAndEmphasis() {
        let t = transcript("So um yesterday Tim Cook told me the new camera costs 300 dollars and the video went viral. INSANE!")
        let tags = KeywordTagger.tag(t)
        let byWord = Dictionary(tags.tags.map { (t.words[$0.word].text, $0) }, uniquingKeysWith: { a, _ in a })

        #expect(byWord["300"]?.kind == .number)
        #expect(byWord["Tim"]?.kind == .person && byWord["Cook"]?.kind == .person)
        #expect(byWord["camera"]?.kind == .noun && byWord["camera"]?.emoji == "📷")
        #expect(byWord["dollars"]?.lemma == "dollar" && byWord["dollars"]?.emoji == "💵")
        #expect(byWord["viral."] == nil)
        #expect(byWord["INSANE!"]?.kind == .emphasis)
        #expect(byWord["um"] == nil)
        #expect(tags.tags.allSatisfy { !t.words[$0.word].isFiller })
        #expect(tags.tags.map(\.word) == tags.tags.map(\.word).sorted())
    }

    @Test func anExclaimedNounIsStillANoun() {
        let t = transcript("It cost three hundred dollars! Thanks! WOW")
        let byWord = Dictionary(KeywordTagger.tag(t).tags.map { (t.words[$0.word].text, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(byWord["dollars!"]?.kind == .noun && byWord["dollars!"]?.emoji == "💵")
        #expect(byWord["Thanks!"]?.kind == .emphasis)
        #expect(byWord["WOW"]?.kind == .emphasis)
    }

    @Test func vagueNounsAndShortNounsWithoutEmojiAreSkipped() {
        let t = transcript("I bought a thing and a car for a bit of fun")
        let lemmas = Set(KeywordTagger.tag(t).tags.map(\.lemma))
        #expect(lemmas.contains("car"))
        #expect(!lemmas.contains("thing") && !lemmas.contains("bit") && !lemmas.contains("fun"))
    }

    @Test func otherLanguagesStillGetNumbers() {
        let t = transcript("Ich habe 25 Euro für das Mikrofon bezahlt", locale: "de-DE")
        let numbers = KeywordTagger.tag(t).tags.filter { $0.kind == .number }
        #expect(numbers.map(\.word) == [2])
    }

    @Test func deterministicAndEmptySafe() {
        let t = transcript("Apple launched the new MacBook in Cupertino on Monday for 1999 dollars")
        #expect(KeywordTagger.tag(t) == KeywordTagger.tag(t))
        #expect(KeywordTagger.tag(Transcript(locale: "en-US", engine: "x", words: [])).tags.isEmpty)
    }
}
