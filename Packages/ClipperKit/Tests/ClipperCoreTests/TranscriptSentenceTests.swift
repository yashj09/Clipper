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
}
