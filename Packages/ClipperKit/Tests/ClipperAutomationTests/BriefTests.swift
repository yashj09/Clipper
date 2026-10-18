import ClipperCore
import Foundation
import Testing
@testable import ClipperAutomation

let briefSpeech = [
    "Welcome back today we test an automatic editor.",
    "Everything runs locally on your own fast machine with no waiting.",
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

/// Source seconds the primary track plays, as (start, end) pairs.
func primarySource(_ t: Timeline) -> [(Double, Double)] {
    t.tracks[0].items.compactMap(\.content.mediaRef).map { ($0.source.start.seconds, $0.source.end.seconds) }
}

func plays(_ t: Timeline, _ w: TranscriptWord) -> Bool {
    primarySource(t).contains { $0.0 <= (w.start + w.end) / 2 && (w.start + w.end) / 2 < $0.1 }
}

@Suite struct ImportanceFitTests {
    @Test func overBudgetDropsTheLeastImportantSentenceNotTheSparsest() throws {
        let brief = TranscriptBrief(model: "m", sentenceImportance: [0.9, 0.1, 0.8, 0.7])
        let input = briefedInput(brief)
        let pieces = Cutting.splitAtSentences(segments(input))
        let sparsest = try #require(pieces.dropFirst().min { $0.density < $1.density })
        #expect(sparsest.words[0].sentence != 1)
        let total = pieces.reduce(0) { $0 + $1.timelineDuration }
        let r = DraftPipeline.run(briefedInput(brief, maxDuration: total - 0.5))
        let words = input.clips[0].analysis.transcript!.words
        let sentences = Transcript.sentences(words)
        #expect(!sentences[1].contains { plays(r.timeline, words[$0]) })
        for s in [0, 2, 3] { #expect(sentences[s].allSatisfy { plays(r.timeline, words[$0]) }) }
        #expect(r.report.notes.contains { $0.hasPrefix("Trimmed to") && $0.hasSuffix("by dropping 1 low-importance sentence") })
    }

    @Test func withoutABriefTrimmingGoesByDensity() {
        let total = segments(briefedInput(nil)).reduce(0) { $0 + $1.timelineDuration }
        let r = DraftPipeline.run(briefedInput(nil, maxDuration: total - 0.5))
        #expect(r.report.notes.contains { $0.contains("low-density segment") })
        #expect(r.timeline.tracks[0].items.count == 1)
    }
}

@Suite struct ColdOpenTests {
    func draft(hook: Int?, rule: HookRule? = HookRule()) -> DraftResult {
        var template = BuiltIns.talkingHead
        template.rules.hook = rule
        return DraftPipeline.run(briefedInput(hook.map { TranscriptBrief(model: "m", hookSentence: $0) }, template: template))
    }

    @Test func hookSentencePlaysFirstAndOnlyOnce() throws {
        let plain = draft(hook: nil).timeline
        let r = draft(hook: 2)
        let t = r.timeline
        let words = briefedInput(nil).clips[0].analysis.transcript!.words
        let sentences = Transcript.sentences(words)
        let items = t.tracks[0].items
        let first = try #require(items.first?.content.mediaRef)
        #expect(abs(first.source.start.seconds - (words[sentences[2].lowerBound].start - 0.08)) < 0.02)
        #expect(sentences[2].allSatisfy { i in
            let mid = (words[i].start + words[i].end) / 2
            return first.source.start.seconds <= mid && mid < first.source.end.seconds
        })
        for w in words {
            let mid = (w.start + w.end) / 2
            #expect(primarySource(t).filter { $0.0 <= mid && mid < $0.1 }.count == 1, "\(w.text) plays once")
        }
        #expect(abs((t.duration - plain.duration).seconds) <= t.canvas.frameRate.frameDuration.seconds)
        #expect(items[1].transition?.kind == .dipToWhite)
        #expect(items.filter { $0.transition != nil }.count == 1)
        #expect(t.markers.first?.time == .zero && t.markers.first?.name.hasPrefix("Hook: “There are no subscriptions") == true)
        #expect(r.report.notes.contains { $0.hasPrefix("Cold open: “There are") })
    }

    @Test func nothingMovesWithoutAUsableHook() {
        let plain = draft(hook: nil).timeline
        #expect(draft(hook: 0).timeline == plain)
        #expect(draft(hook: 2, rule: HookRule(maxSeconds: 2)).timeline == plain)
        #expect(draft(hook: 2, rule: nil).timeline == plain)
        var template = BuiltIns.talkingHead
        template.rules.hook = nil
        #expect(DraftPipeline.run(briefedInput(nil, template: template)).timeline == plain)
    }

    @Test func lowImportanceHookStaysPut() {
        var template = BuiltIns.talkingHead
        template.rules.hook = HookRule()
        let brief = TranscriptBrief(model: "m", hookSentence: 2, sentenceImportance: [0.9, 0.8, 0.5, 0.7])
        let r = DraftPipeline.run(briefedInput(brief, template: template))
        #expect(!r.report.notes.contains { $0.hasPrefix("Cold open") })
    }
}

@Suite struct KeywordTests {
    func tagged(_ tags: [KeywordTags.Tag]) -> ClipInput {
        var clip = briefedInput(nil).clips[0]
        clip.analysis.keywords = KeywordTags(tags: tags)
        return clip
    }

    @Test func namesNumbersAndEmojiNounsAreKeywords() {
        let plan = SpeechPlan(clip: tagged([
            .init(word: 1, kind: .person, lemma: "back"), .init(word: 7, kind: .noun, lemma: "editor"),
            .init(word: 15, kind: .noun, lemma: "machine", emoji: "💻"), .init(word: 27, kind: .emphasis, lemma: "all"),
            .init(word: 30, kind: .number, lemma: "by"),
        ]), rule: nil)
        let keywords = plan.words.filter { $0.cue.contains(.keyword) }.map(\.text)
        #expect(keywords == ["back", "machine", "by"])
        #expect(plan.words[15].emoji == "💻")
        #expect(Cue.keyword.highlights && !Cue.keyword.zooms)
        #expect(Cue([.keyword, .caps]).zooms)
    }

    func word(_ text: String, at t: Double, keyword: Bool = false, emoji: String? = nil) -> TimedWord {
        TimedWord(text: text, start: t, end: t + 0.3, isFiller: false, cue: keyword ? .keyword : [], emoji: emoji)
    }

    @Test func captionPagesAfterTheFirstGetOneEmoji() {
        let words = [word("Save", at: 0.5, keyword: true, emoji: "💾"), word("money.", at: 0.85, keyword: true, emoji: "💰"),
                     word("Real", at: 2, keyword: true, emoji: "✅"), word("money", at: 2.35, keyword: true, emoji: "💰"),
                     word("now.", at: 2.7), word("No", at: 4), word("emoji", at: 4.35, emoji: "😀")]
        var ids = IDGenerator(seed: 1)
        let style = BuiltIns.styles["bold-pop"]!
        let pages = Captions.items(words: words, styleName: "bold-pop", style: style, rate: .fps30, emoji: true, ids: &ids)
            .compactMap { item -> [String]? in if case .caption(let c) = item.content { c.words.map(\.text) } else { nil } }
        #expect(pages == [["Save", "money"], ["Real ✅", "money", "now"], ["No", "emoji"]])
        var plainIDs = IDGenerator(seed: 1)
        let plain = Captions.items(words: words, styleName: "bold-pop", style: style, rate: .fps30, ids: &plainIDs)
        #expect(!plain.contains { if case .caption(let c) = $0.content { c.text.contains("✅") } else { false } })
    }

    @Test func calloutsSkipTheTitleAndEndAndKeepTheirDistance() {
        let words = [word("Apple", at: 1, keyword: true), word("49%,", at: 3, keyword: true), word("Paris", at: 6, keyword: true),
                     word("pizza.", at: 11.5, keyword: true, emoji: "🍕"), word("plain", at: 13), word("Rome", at: 19.5, keyword: true)]
        var ids = IDGenerator(seed: 1)
        let picked = Visual.calloutWords(words, rule: CalloutRule(), duration: 20)
        let items = Visual.callouts(picked, rule: CalloutRule(), styles: BuiltIns.styles, rate: .fps30, duration: 20, ids: &ids)
        #expect(items.compactMap { if case .text(let t) = $0.content { t.text } else { nil } } == ["49%", "pizza 🍕"])
        #expect(items[1].range.duration == RationalTime.frames(1.6, .fps30))
        #expect(items.allSatisfy { $0.origin == .auto(pass: "callouts") && $0.transform.position == .constant(NormPoint(0.5, 0.30)) })
    }

    @Test func talkingHeadDraftsGetACalloutTrack() throws {
        var input = briefedInput(nil)
        input.clips[0].analysis.keywords = KeywordTags(tags: [.init(word: 22, kind: .noun, lemma: "subscription", emoji: "💸")])
        let r = DraftPipeline.run(input)
        let track = try #require(r.timeline.tracks.first { $0.name == "Callouts" })
        #expect(track.kind == .overlay && track.items.count == 1)
        #expect(r.report.notes.contains("Added 1 callout"))
        let callout = try #require(track.items.first)
        #expect(callout.content == .text(TextContent(text: "subscriptions 💸", style: "callout")))
        let captions = try #require(r.timeline.tracks.first { $0.kind == .caption })
        #expect(captions.items.contains { if case .caption(let c) = $0.content { c.words.contains { $0.text == "subscriptions" } } else { false } })
        #expect(!captions.items.contains { if case .caption(let c) = $0.content { c.text.contains("💸") } else { false } })
    }
}

@Suite struct ChapterMarkerTests {
    @Test func chaptersMarkWhereTheyPlay() throws {
        let words = briefedInput(nil).clips[0].analysis.transcript!.words
        // The 1.6 s pause after sentence 1 is cut; its first half is more than a second before the kept footage.
        let deepInCut = words[18].end + 0.3
        let brief = TranscriptBrief(model: "m", chapters: [
            .init(start: words[0].start - 0.4, title: "Intro"), .init(start: deepInCut, title: "In a cut"),
            .init(start: words[19].start, title: "No cloud"), .init(start: words[19].start + 1, title: "Too close"),
            .init(start: words[28].start, title: "Timing"),
        ])
        let t = DraftPipeline.run(briefedInput(brief)).timeline
        #expect(t.markers.map(\.name) == ["Chapter: Intro", "Chapter: No cloud", "Chapter: Timing"])
        #expect(t.markers[0].time == .zero)
        let marker = try #require(t.markers.first { $0.name == "Chapter: No cloud" })
        let item = try #require(t.tracks[0].items.first { $0.range.contains(marker.time) })
        let ref = try #require(item.content.mediaRef)
        let source = ref.source.start.seconds + (marker.time - item.start).seconds
        #expect(abs(source - words[19].start) <= t.canvas.frameRate.frameDuration.seconds)
        #expect(DraftPipeline.run(briefedInput(brief)).timeline == t)
    }
}
