import ClipperCore
import Foundation
import Testing
@testable import ClipperAutomation

@Suite struct SpeedUpTests {
    let fast = SilenceCutRule(minGap: 0.4, padBefore: 0.08, padAfter: 0.12, speedUp: SpeedUpRule())
    var hard: SilenceCutRule { var r = fast; r.speedUp = nil; return r }

    @Test func shortPauseIsKeptFastBetweenThePaddedSpeech() {
        let tr = transcript(["one two three", "four five six"], pauses: [1.0])
        let pieces = Cutting.keepRanges(words: tr.words, speech: nil, clip: 0...10, rule: fast)
        #expect(pieces.map(\.speed) == [1, 2.5, 1])
        #expect(pieces[1].range.lowerBound == pieces[0].range.upperBound, "speech runs straight into the pause")
        #expect(pieces[1].range.upperBound == pieces[2].range.lowerBound, "the pause runs straight into speech")
        #expect(abs(pieces[1].range.lowerBound - (tr.words[2].end + 0.12)) < 1e-9)
        #expect(abs(pieces[1].range.upperBound - (tr.words[3].start - 0.08)) < 1e-9)

        let cut = Cutting.keepRanges(words: tr.words, speech: nil, clip: 0...10, rule: hard)
        #expect(cut.map(\.speed) == [1, 1])
        #expect(cut == pieces.filter { $0.speed == 1 }, "speed-up only adds the pause; speech pieces are unchanged")
    }

    @Test func longPauseIsStillCut() {
        let tr = transcript(["one two three", "four five six"], pauses: [3])
        let pieces = Cutting.keepRanges(words: tr.words, speech: nil, clip: 0...10, rule: fast)
        #expect(pieces.map(\.speed) == [1, 1])
    }

    @Test func pauseHoldingAFillerOrAnEditIsStillCut() {
        let um = transcript(["one two three", "um", "four five six"], pauses: [0.4, 0.4])
        let pieces = Cutting.keepRanges(words: um.words, speech: nil, clip: 0...10, rule: fast)
        #expect(pieces.map(\.speed) == [1, 1])
        let filler = um.words.first { $0.isFiller }!
        #expect(!pieces.contains { $0.range.contains((filler.start + filler.end) / 2) })

        let tr = transcript(["one two three", "four five six"], pauses: [1.0])
        let excluded = RangeSet([1.9..<2.1])
        #expect(Cutting.keepRanges(words: tr.words, speech: nil, clip: 0...10, rule: fast, excluded: excluded).map(\.speed) == [1, 1])
    }

    @Test func fastPausesCarryNoWordsAndAreNotTrimmedAsBroll() {
        let tr = transcript(["one two three", "four five six"], pauses: [1.0])
        let clip = ClipInput(asset: videoAsset("speaker", seconds: 10), analysis: AssetAnalysis(transcript: tr))
        let segs = Cutting.segments(for: 0, clip: clip, rule: fast, plan: SpeechPlan(clip: clip, rule: nil))
        #expect(segs.map(\.speed) == [1, 2.5, 1])
        #expect(segs[1].words.isEmpty)
        #expect(abs(segs[1].timelineDuration - segs[1].duration / 2.5) < 1e-12)
        #expect(Cutting.trimSilent(segs, maxLength: 0.2) == segs)
    }
}
