import ClipperCore
import Foundation
import Testing
@testable import ClipperAutomation

let briefSpeech = [
    "Welcome back today we test an automatic editor.",
    "Everything runs locally on your own machine.",
    "There are no subscriptions and no uploads at all!",
    "Timing off by a few frames gets noticed.",
]

/// `talkingInput` with four sentences in two segments (sentences 0 and 1, then 2 and 3) and an LLM brief.
func briefedInput(_ brief: TranscriptBrief?, template: Template = BuiltIns.talkingHead, maxDuration: Double? = nil) -> DraftInput {
    var input = talkingInput()
    input.clips[0].analysis = AssetAnalysis(transcript: transcript(briefSpeech, pauses: [0.2, 1.6, 0.2, 2.5]), brief: brief)
    input.template = template
    input.settings.maxDuration = maxDuration
    return input
}

func segments(_ input: DraftInput) -> [Segment] {
    let clip = input.clips[0]
    let plan = SpeechPlan(clip: clip, rule: input.template.rules.speechEdits)
    return Cutting.segments(for: 0, clip: clip, rule: input.template.rules.silenceCut, plan: plan)
}

@Suite struct SentenceTests {
    @Test func wordsCarryTheirSentenceInTheWholeTranscript() {
        let tr = transcript(["One two.", "Um three four.", "Five six."], pauses: [0.2, 0.2])
        var clip = speakerClip(tr)
        clip.inPoint = tr.words[3].start
        let plan = SpeechPlan(clip: clip, rule: nil)
        #expect(plan.words.map(\.text) == ["three", "four.", "Five", "six."])
        #expect(plan.words.map(\.sentence) == [1, 1, 2, 2])
        let whole = SpeechPlan(clip: speakerClip(tr), rule: nil)
        #expect(whole.words.first { $0.isFiller }?.sentence == 1)
    }

    @Test func importanceNeedsAScoreForEverySentence() {
        let input = briefedInput(TranscriptBrief(model: "m", sentenceImportance: [0.9, 0.2, 0.5, 0.7]))
        let plan = SpeechPlan(clip: input.clips[0], rule: nil)
        #expect(plan.words.first { $0.sentence == 1 }?.importance == 0.2)
        let short = briefedInput(TranscriptBrief(model: "m", sentenceImportance: [0.9, 0.2]))
        #expect(SpeechPlan(clip: short.clips[0], rule: nil).words.allSatisfy { $0.importance == nil })
    }

    @Test func splittingAtSentencesKeepsTheSameFootage() {
        let input = briefedInput(TranscriptBrief(model: "m", sentenceImportance: [0.9, 0.2, 0.5, 0.7]))
        let segs = segments(input)
        let split = Cutting.splitAtSentences(segs)
        // Sentences 0 and 1 (and 2 and 3) are 0.25 s apart, under the 0.35 s silence cut: one segment, two pieces.
        #expect(segs.count == 2)
        #expect(split.count == 4)
        for piece in split { #expect(Set(piece.words.map(\.sentence)).count == 1) }
        #expect(split[0].end == split[1].start && split[2].end == split[3].start)
        #expect(split[0].start == segs[0].start && split[1].end == segs[0].end)
        #expect(split[0].importance == 0.9 && split[1].importance == 0.2)
        #expect(segs[0].importance == 0.9)
        #expect(Cutting.joinContinuous(split) == segs)
    }

    @Test func tightSentencesStayTogether() {
        let tr = transcript(["One two.", "Three four."], pauses: [-0.02])
        let clip = speakerClip(tr)
        let segs = Cutting.segments(for: 0, clip: clip, rule: SilenceCutRule(), plan: SpeechPlan(clip: clip, rule: nil))
        #expect(Cutting.splitAtSentences(segs) == segs)
    }
}
