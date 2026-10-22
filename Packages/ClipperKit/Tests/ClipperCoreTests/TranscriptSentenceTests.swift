import ClipperCore
import Testing

@Suite struct TranscriptSentenceTests {
    private func w(_ text: String, _ start: Double, filler: Bool = false) -> TranscriptWord {
        TranscriptWord(text: text, start: start, end: start + 0.3, isFiller: filler)
    }

    @Test func splitsOnEndPunctuationAndLongPauses() {
        let words = [w("Hi.", 0), w("Is", 0.4), w("it?", 0.8), w("yes", 1.2), w("then", 2.5), w("go!", 2.9), w("ok", 3.3)]
        #expect(Transcript.sentences(words) == [0..<1, 1..<3, 3..<4, 4..<6, 6..<7])
    }

    @Test func fillersDoNotHideAPauseAndTrailingFillersStayAttached() {
        // "so" ends at 0.3 and the next real word starts at 1.2: the "um" between them does not bridge the pause.
        let words = [w("so", 0), w("um", 0.5, filler: true), w("right", 1.2), w("uh", 1.6, filler: true)]
        #expect(Transcript.sentences(words) == [0..<1, 1..<4])
        #expect(Transcript.sentences([]).isEmpty)
    }

    @Test func abbreviationsInitialsAndEllipsesDoNotEndASentence() {
        let words = [w("Dr.", 0), w("Smith", 0.4), w("e.g.", 0.8), w("J.", 1.2), w("Doe", 1.6), w("Wait...", 2.0), w("what", 2.4), w("now.", 2.8),
                     w("Wait...", 3.2), w("What?", 3.6), w("Mt.", 4.0), w("Fuji.", 4.4)]
        #expect(Transcript.sentences(words) == [0..<8, 8..<9, 9..<10, 10..<12])
        #expect(Transcript.endsSentence("done.") && Transcript.endsSentence("ok!") && Transcript.endsSentence("why?", next: "because"))
        #expect(!Transcript.endsSentence("Dr.", next: "Who") && !Transcript.endsSentence("wait.", next: "no") && !Transcript.endsSentence("plain"))
    }
}
