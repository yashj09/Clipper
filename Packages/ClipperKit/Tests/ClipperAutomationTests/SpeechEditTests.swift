import ClipperCore
import Foundation
import Testing
@testable import ClipperAutomation

func speakerClip(_ tr: Transcript, seconds: Double = 60, speech: SpeechActivity? = nil) -> ClipInput {
    ClipInput(asset: videoAsset("speaker", seconds: seconds), analysis: AssetAnalysis(transcript: tr, speech: speech))
}

func kept(_ plan: SpeechPlan) -> [String] { plan.words.map(\.text) }

@Suite struct FalseStartTests {
    @Test func stutterDropsFirstOccurrence() {
        let tr = transcript(["I I think this works."], pauses: [])
        let plan = SpeechPlan(clip: speakerClip(tr), rule: SpeechEditRule())
        #expect(kept(plan) == ["I", "think", "this", "works."])
        #expect(plan.removedRestarts == 1)
        let first = tr.words[0]
        #expect(plan.excluded.contains((first.start + first.end) / 2))
        #expect(!plan.excluded.contains((tr.words[1].start + tr.words[1].end) / 2))
    }

    @Test func intentionalDoublesAreKept() {
        let tr = transcript(["This is very very good and I knew that that was it."], pauses: [])
        let plan = SpeechPlan(clip: speakerClip(tr), rule: SpeechEditRule())
        #expect(plan.excluded.isEmpty)
        #expect(kept(plan).count == tr.words.count)
    }

    @Test func fragmentThenRestartDropsFragment() {
        for fragment in ["So the", "So the thing,"] {
            let tr = transcript([fragment, "so the main thing is speed."], pauses: [0.4])
            let plan = SpeechPlan(clip: speakerClip(tr), rule: SpeechEditRule())
            #expect(kept(plan) == ["so", "the", "main", "thing", "is", "speed."], "\(fragment)")
            #expect(plan.removedRestarts == 1)
        }
        let parallel = transcript(["I like cats, I like dogs."], pauses: [])
        #expect(SpeechPlan(clip: speakerClip(parallel), rule: SpeechEditRule()).excluded.isEmpty)
    }

    @Test func completeSentenceIsNotAFragment() {
        let tr = transcript(["It works.", "It works great."], pauses: [0.3])
        #expect(SpeechPlan(clip: speakerClip(tr), rule: SpeechEditRule()).excluded.isEmpty)
    }

    @Test func fillersBetweenFragmentAndRestartGoWithIt() {
        let tr = transcript(["I, um, I think so."], pauses: [])
        let plan = SpeechPlan(clip: speakerClip(tr), rule: SpeechEditRule())
        #expect(kept(plan) == ["I", "think", "so."])
    }

    @Test func singleWordStuttersNeedAnEnglishTranscript() {
        var tr = transcript(["the the end", "so the, so the main thing."], pauses: [0.5])
        tr.locale = "fr-FR"
        let plan = SpeechPlan(clip: speakerClip(tr), rule: SpeechEditRule())
        #expect(kept(plan) == ["the", "the", "end", "so", "the", "main", "thing."])
    }

    @Test func offOrNoRuleKeepsEveryWord() {
        let tr = transcript(["I I think this works."], pauses: [])
        #expect(SpeechPlan(clip: speakerClip(tr), rule: nil).excluded.isEmpty)
        #expect(SpeechPlan(clip: speakerClip(tr), rule: SpeechEditRule(falseStarts: false)).excluded.isEmpty)
    }

    @Test func cutterNeverKeepsExcludedTime() {
        let inputs = [
            transcript(["I I think this works."], pauses: []),
            transcript(["So the", "so the main thing is speed."], pauses: [0.4]),
            transcript(["So the thing,", "so the main thing is speed."], pauses: [0.4]),
        ]
        for tr in inputs {
            let clip = speakerClip(tr, seconds: 10)
            let plan = SpeechPlan(clip: clip, rule: SpeechEditRule())
            #expect(!plan.excluded.isEmpty)
            for rule in [SilenceCutRule(), SilenceCutRule(minGap: 2, padBefore: 0.3, padAfter: 0.3)] {
                let ranges = Cutting.keepRanges(words: tr.words, speech: nil, clip: clip.range, rule: rule, excluded: plan.excluded)
                #expect(!ranges.isEmpty)
                #expect(ranges.allSatisfy { plan.excluded.isDisjoint(RangeSet($0.lowerBound..<$0.upperBound)) }, "\(ranges)")
            }
            let whole = Cutting.segments(for: 0, clip: clip, rule: nil, plan: plan)
            #expect(whole.count == 2)
            #expect(whole.allSatisfy { plan.excluded.isDisjoint(RangeSet($0.start..<$0.end)) })
        }
    }

    @Test func draftReportsFalseStarts() {
        var input = talkingInput()
        input.template.rules.speechEdits = SpeechEditRule()
        input.clips[0].analysis.transcript = transcript(["So the", "so the main thing is that it is all local.", "I I think so."],
                                                        pauses: [0.4, 1, 1])
        let r = DraftPipeline.run(input)
        #expect(r.report.removedRestarts == 2)
        #expect(r.report.notes.contains("Removed 2 false starts"))
        let captions = r.timeline.tracks.first { $0.kind == .caption }!.items
        let words = captions.flatMap { item -> [String] in if case .caption(let c) = item.content { c.words.map(\.text) } else { [] } }
        #expect(words.prefix(3).map { $0.lowercased() } == ["so", "the", "main"])
    }
}
