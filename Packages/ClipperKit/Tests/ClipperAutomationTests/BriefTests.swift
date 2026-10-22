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

    @Test func aSilentSegmentDoesNotSwitchImportanceTrimmingOff() {
        func words(_ n: Int, at t: Double, importance: Double) -> [SpokenWord] {
            Array(repeating: SpokenWord(word: TranscriptWord(text: "w", start: t, end: t + 0.2), cue: [], importance: importance), count: n)
        }
        let segs = [Segment(clip: 0, start: 0, end: 5, words: words(10, at: 1, importance: 0.9)),
                    Segment(clip: 0, start: 6, end: 11, words: []),
                    Segment(clip: 0, start: 12, end: 17, words: words(4, at: 13, importance: 0.2)),
                    Segment(clip: 0, start: 18, end: 23, words: words(12, at: 19, importance: 0.8))]
        #expect(Cutting.scored(segs))
        var report = DraftReport()
        let out = Cutting.fit(segs, maxDuration: 11, report: &report)
        #expect(out.map(\.start) == [0, 18])
        #expect(report.notes.contains { $0.hasSuffix("by dropping 1 low-importance sentence") })
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
        // A brief always leaves its description and hashtags on the timeline; only the edit must stay the same.
        func edit(_ t: Timeline) -> Timeline { var t = t; t.metadata = nil; return t }
        #expect(edit(draft(hook: 0).timeline) == plain)
        #expect(edit(draft(hook: 2, rule: HookRule(maxSeconds: 2)).timeline) == plain)
        #expect(edit(draft(hook: 2, rule: nil).timeline) == plain)
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

@Suite struct ColdOpenChapterTests {
    @Test func chaptersFollowTheBodyNotTheHook() throws {
        let words = briefedInput(nil).clips[0].analysis.transcript!.words
        let sentences = Transcript.sentences(words)
        var template = BuiltIns.talkingHead
        template.rules.hook = HookRule()
        let brief = TranscriptBrief(model: "m", hookSentence: 2, chapters: [
            .init(start: words[0].start - 0.3, title: "Intro"), .init(start: words[sentences[2].lowerBound].start, title: "No cloud"),
        ])
        let t = DraftPipeline.run(briefedInput(brief, template: template)).timeline
        let items = t.tracks[0].items
        #expect(t.markers.map(\.name).dropFirst() == ["Chapter: Intro", "Chapter: No cloud"] && t.markers[0].name.hasPrefix("Hook: “There are"))
        // "Intro" marks where the body starts after the jump, not the hook at 0; "No cloud" marks where the hook's
        // chapter goes on (sentence 3), not the hook itself.
        #expect(t.markers[1].time == items[1].start && items[1].start > .zero)
        let body = try #require(items.first { item in
            item.content.mediaRef.map { $0.source.start.seconds <= words[sentences[3].lowerBound].start && words[sentences[3].lowerBound].start < $0.source.end.seconds } ?? false
        })
        #expect(t.markers[2].time == body.start)
        #expect(t.markers.allSatisfy { $0.origin.isAuto })
    }

    @Test func aChapterOnTheHookSurvivesALongPauseAfterIt() throws {
        // Sentence 1 as the hook; the 1.6 s pause after it is cut, so the body goes on well over a second later.
        // One chapter only: the test sentences are too close for two to be 3 s apart.
        let words = briefedInput(nil).clips[0].analysis.transcript!.words
        let sentences = Transcript.sentences(words)
        var template = BuiltIns.talkingHead
        template.rules.hook = HookRule(maxSeconds: 10, minImportance: 0)
        let brief = TranscriptBrief(model: "m", hookSentence: 1,
                                    chapters: [.init(start: words[sentences[1].lowerBound].start, title: "Second")])
        let t = DraftPipeline.run(briefedInput(brief, template: template)).timeline
        let second = try #require(t.markers.first { $0.name == "Chapter: Second" })
        let plays = try #require(t.tracks[0].items.first { $0.start == second.time }?.content.mediaRef)
        #expect(plays.source.start.seconds <= words[sentences[2].lowerBound].start && words[sentences[2].lowerBound].start < plays.source.end.seconds)
    }

    @Test func aFillerOnlyHookThatAlreadyOpensTheDraftIsLeftAlone() {
        var clip = ClipInput(asset: videoAsset("speaker", seconds: 10))
        clip.analysis.brief = TranscriptBrief(model: "m", hookSentence: 0)
        let um = SpokenWord(word: TranscriptWord(text: "Um.", start: 0.1, end: 0.4, isFiller: true), cue: [], sentence: 0)
        let hi = SpokenWord(word: TranscriptWord(text: "Hello.", start: 1.0, end: 1.4), cue: [], sentence: 1)
        let segs = [Segment(clip: 0, start: 0, end: 0.5, words: [um]), Segment(clip: 0, start: 0.9, end: 1.5, words: [hi])]
        #expect(Hook.coldOpen(segs, clips: [clip], rule: HookRule(maxSeconds: 10, minImportance: 0)) == nil)
    }

    @Test func profanityIsMaskedInTheHook() throws {
        var input = profaneInput(ProfanityRule())
        input.template.rules.hook = HookRule(maxSeconds: 10, minImportance: 0)
        input.clips[0].analysis.brief = TranscriptBrief(model: "m", hookSentence: 1)
        var plan = SpeechPlan(clip: input.clips[0], rule: input.template.rules.speechEdits)
        plan.markProfanity(locale: "en-US")
        let segs = Cutting.segments(for: 0, clip: input.clips[0], rule: input.template.rules.silenceCut, plan: plan)
        let open = try #require(Hook.coldOpen(segs, clips: input.clips, rule: input.template.rules.hook!))
        #expect(open.text.hasSuffix("runs f****** locally.") && !open.text.contains("fucking"))
        let r = DraftPipeline.run(input)
        #expect(r.report.notes.contains { $0.hasPrefix("Cold open:") } && !r.report.notes.contains { $0.contains("fucking") })
        #expect(r.timeline.markers.contains { $0.name.hasPrefix("Hook:") } && !r.timeline.markers.contains { $0.name.contains("fucking") })
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

    @Test func anUnknownCalloutStyleWarnsAndChangesNothingElse() throws {
        var input = briefedInput(nil)
        input.clips[0].analysis.keywords = KeywordTags(tags: [.init(word: 22, kind: .noun, lemma: "subscription", emoji: "💸")])
        input.template.rules.callouts = CalloutRule(style: "nope")
        input.sfx = sfxAssets()
        let r = DraftPipeline.run(input)
        #expect(r.report.warnings.contains { $0.hasPrefix("Unknown callout style 'nope'") })
        #expect(!r.timeline.tracks.contains { $0.name == "Callouts" })
        let captions = try #require(r.timeline.tracks.first { $0.kind == .caption })
        #expect(captions.items.contains { if case .caption(let c) = $0.content { c.text.contains("💸") } else { false } })
        let pops = r.timeline.tracks.filter { $0.name == "SFX" }.flatMap(\.items).filter { $0.content.mediaRef?.asset == input.sfx[.pop]?.id }
        #expect(pops.isEmpty)
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
