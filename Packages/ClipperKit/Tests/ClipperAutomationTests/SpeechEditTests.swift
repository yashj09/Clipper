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

@Suite struct RetakeTests {
    @Test func retakesKeepLastCompleteTake() {
        let tr = transcript(["Today we are testing the new editor.", "Today we are testing the new editor on a laptop.",
                             "Today we are testing the new", "Next we look at captions."], pauses: [1.5, 1.5, 1.5])
        let plan = SpeechPlan(clip: speakerClip(tr), rule: SpeechEditRule(takes: .last))
        #expect(plan.removedTakes == 2)
        #expect(plan.retakes.map(\.take) == [1])
        #expect(kept(plan) == "Today we are testing the new editor on a laptop. Next we look at captions.".split(separator: " ").map(String.init))
        let segments = Cutting.segments(for: 0, clip: speakerClip(tr), rule: SilenceCutRule(), plan: plan)
        #expect(segments.allSatisfy { plan.excluded.isDisjoint(RangeSet($0.start..<$0.end)) })
        #expect(segments.flatMap(\.words).map(\.text) == kept(plan))
        #expect(SpeechPlan(clip: speakerClip(tr), rule: SpeechEditRule(takes: nil)).retakes.isEmpty)
    }

    @Test func bestPolicyPicksCleanTake() {
        let messy = "Um so this uh runs fully offline.", clean = "So this runs fully offline."
        for order in [[messy, clean], [clean, messy]] {
            var tr = transcript(order, pauses: [1.5])
            tr.words = tr.words.map { var w = $0; w.confidence = order[0] == messy ? (w.start < 3 ? 0.6 : 0.9) : (w.start < 2.5 ? 0.9 : 0.6); return w }
            let best = SpeechPlan(clip: speakerClip(tr), rule: SpeechEditRule(takes: .best))
            #expect(kept(best) == clean.split(separator: " ").map(String.init), "\(order)")
            let last = SpeechPlan(clip: speakerClip(tr), rule: SpeechEditRule(takes: .last))
            #expect(kept(last) == order[1].split(separator: " ").map(String.init))
        }
    }

    @Test func distantOrSeparatedRepeatsAreNotRetakes() {
        let line = "This editor runs entirely on your own laptop."
        let separated = transcript([line, "Captions are generated on device.", "Music ducks under your voice.",
                                    "Exports land in the folder you pick.", "Nothing is ever uploaded anywhere.", line],
                                   pauses: [1, 1, 1, 1, 1])
        #expect(SpeechPlan(clip: speakerClip(separated), rule: SpeechEditRule()).retakes.isEmpty)
        let distant = transcript([line, line], pauses: [100])
        #expect(SpeechPlan(clip: speakerClip(distant, seconds: 120), rule: SpeechEditRule()).retakes.isEmpty)
        let fragment = transcript(["This editor runs entirely on your own laptop and also on the old desktop in the office.",
                                   "This editor runs entirely"], pauses: [1.5])
        #expect(SpeechPlan(clip: speakerClip(fragment), rule: SpeechEditRule()).retakes.isEmpty)
    }

    @Test func draftReportsAndMarksRetakes() throws {
        var input = talkingInput()
        input.clips[0].analysis.transcript = transcript(
            ["Welcome back, today we are testing an automatic editor.", "Welcome back, today we are testing an automatic video editor.",
             "Everything runs locally on your own machine."], pauses: [1.2, 1.2])
        let r = DraftPipeline.run(input)
        #expect(r.report.removedTakes == 1)
        #expect(r.report.notes.contains("Removed 1 retake"))
        let markers = r.timeline.markers
        try #require(markers.count == 1)
        let video = r.timeline.tracks.first { $0.kind == .video }!
        let keptStart = video.items[0].start.seconds + 0.08   // the first kept word, after the silence cut's lead-in
        #expect(abs(markers[0].time.seconds - keptStart) < 0.04)
        #expect(markers[0].name.hasPrefix("Retake: kept take 2 of 2 · removed 0:00.5–"))
        let plain = DraftPipeline.run(talkingInput())
        #expect(plain.timeline.markers.isEmpty && plain.report.removedTakes == 0 && plain.report.removedRestarts == 0)
        let again = DraftPipeline.run(input)
        #expect(try ClipperJSON.encode(again.timeline) == ClipperJSON.encode(r.timeline))
    }

    @Test func takesDecodeWithDefaultsAndRoundTripNull() throws {
        #expect(try ClipperJSON.decode(SpeechEditRule.self, from: Data("{}".utf8)) == SpeechEditRule())
        #expect(try ClipperJSON.decode(SpeechEditRule.self, from: Data(#"{"takes": null}"#.utf8)).takes == nil)
        let off = SpeechEditRule(takes: nil, falseStarts: false)
        #expect(try ClipperJSON.decode(SpeechEditRule.self, from: ClipperJSON.encode(off)) == off)
        #expect(try ClipperJSON.decode(Rules.self, from: Data("{}".utf8)).speechEdits == nil)
    }
}

@Suite struct EmphasisZoomTests {
    func evenWords(until end: Double, cue: Cue = []) -> [TimedWord] {
        stride(from: 0.5, to: end, by: 0.35).map { TimedWord(text: "word", start: $0, end: $0 + 0.3, isFiller: false, cue: cue) }
    }

    /// Longest time between visual changes (cuts, move starts, the ends of the timeline).
    func longestStill(_ curve: ZoomCurve, cuts: [Double], end: Double) -> Double {
        let changes = ([0, end] + cuts + curve.moves.map(\.start)).sorted()
        return zip(changes, changes.dropFirst()).map { $1 - $0 }.max() ?? 0
    }

    @Test func loudWordDrivesCaptionAndZoom() throws {
        let line = "this whole editor runs on your machine and every cut lands where you expect it to land without any upload at all"
        let tr = transcript([line], pauses: [])
        let loud = tr.words[13]
        let hop = 0.01
        let rms = (0..<3000).map { i -> Float in
            let t = Double(i) * hop
            return t >= loud.start && t < loud.end ? -24 : -30
        }
        let speech = SpeechActivity(spans: [], rms: Envelope(hop: hop, values: rms), noiseFloor: -60, threshold: -50)
        let input = DraftInput(template: BuiltIns.talkingHead, clips: [speakerClip(tr, seconds: 30, speech: speech)],
                               settings: DraftSettings(seed: 3))
        let plan = SpeechPlan(clip: input.clips[0], rule: SpeechEditRule())
        #expect(plan.words[13].cue.contains(.loud))
        #expect(plan.words.filter { $0.cue.contains(.loud) }.count == 1)

        let r = DraftPipeline.run(input)
        let video = try #require(r.timeline.tracks.first { $0.kind == .video })
        try #require(video.items.count == 1)
        let item = video.items[0]
        let at = loud.start - item.content.mediaRef!.source.start.seconds
        #expect(item.transform.zoom.keys.contains { abs($0.time.seconds - at) < 0.01 && $0.interpolation == .easeInOut },
                "\(item.transform.zoom.keys)")
        let captions = try #require(r.timeline.tracks.first { $0.kind == .caption })
        let highlighted = captions.items.flatMap { i -> [String] in
            if case .caption(let c) = i.content { c.words.filter(\.emphasis).map(\.text) } else { [] }
        }
        #expect(highlighted == ["expect"])
        #expect(r.report.notes.contains { $0.hasPrefix("Added ") && $0.contains("on emphasis") })
    }

    @Test func zoomCurveSpacesRampsAndAlternates() {
        let curve = Visual.zoomCurve(words: evenWords(until: 20, cue: .number), cuts: [], end: 20,
                                     rule: PunchInRule(zoom: 1.12, minSpacing: 4, rampDuration: 0.25))
        #expect(curve.moves.count >= 4)
        #expect(zip(curve.moves, curve.moves.dropFirst()).allSatisfy { $1.start - $0.start >= 4 })
        #expect(curve.moves.allSatisfy { $0.duration == 0.25 && $0.reason == .emphasis })
        #expect(curve.moves.enumerated().allSatisfy { i, m in m.to == (i % 2 == 0 ? 1.12 : 1) })
    }

    @Test func emphasisJustAfterACutStepsOnTheCut() {
        let words = [TimedWord(text: "NOW", start: 5.1, end: 5.4, isFiller: false, cue: .caps)]
        let curve = Visual.zoomCurve(words: words, cuts: [5], end: 8, rule: PunchInRule(minSpacing: 4, maxStill: 0))
        #expect(curve.moves == [.init(start: 5, duration: 0, to: 1.15, reason: .emphasis)])
    }

    @Test func pacingFillsLongStills() throws {
        let rule = PunchInRule(zoom: 1.12, minSpacing: 4, rampDuration: 0.25, maxStill: 6)
        let words = evenWords(until: 20)
        let curve = Visual.zoomCurve(words: words, cuts: [], end: 20, rule: rule)
        let first = try #require(curve.moves.first)
        #expect(first.start == words.first { $0.start >= 6 }!.start)
        #expect(curve.moves.allSatisfy { $0.reason == .pacing })
        #expect(longestStill(curve, cuts: [], end: 20) <= 6.35)
        let cut = Visual.zoomCurve(words: words, cuts: [3], end: 20, rule: rule)
        #expect(try #require(cut.moves.first).start >= 9)
        #expect(longestStill(cut, cuts: [3], end: 20) <= 6.35)
        var off = rule
        off.maxStill = 0
        #expect(Visual.zoomCurve(words: words, cuts: [], end: 20, rule: off).moves.isEmpty)
        let silent = Visual.zoomCurve(words: [], cuts: [], end: 20, rule: rule)
        #expect(silent.moves.map(\.start) == [6, 12, 18])

        let old = try ClipperJSON.decode(PunchInRule.self, from: Data(#"{"zoom": 1.1, "minSpacing": 4, "rampDuration": 0.2}"#.utf8))
        #expect(old.maxStill == 6)
        #expect(try ClipperJSON.decode(PunchInRule.self, from: ClipperJSON.encode(off)) == off)
    }

    @Test func curveIsSampledPerItem() {
        let curve = ZoomCurve(moves: [.init(start: 4, duration: 0.25, to: 1.12, reason: .emphasis)])
        let first = curve.zoom(over: TimeRange(seconds: 0, 6), base: 1)
        #expect(first.keys.map(\.time.seconds) == [0, 4, 4.25])
        #expect(first.keys.map(\.value) == [1, 1, 1.12])
        #expect(curve.zoom(over: TimeRange(seconds: 6, 14), base: 1.1) == .constant(1.1 * 1.12))

        var items = [Item(name: "a", range: TimeRange(seconds: 0, 6), content: .text(TextContent(text: "a", style: "s"))),
                     Item(name: "b", range: TimeRange(seconds: 6, 14), content: .text(TextContent(text: "b", style: "s")))]
        items[1].transform.zoom = .keyframes([Keyframe(.zero, 1), Keyframe(RationalTime(seconds: 2), 2)])
        let words = [TimedWord(text: "60", start: 4, end: 4.3, isFiller: false, cue: .number)]
        let out = Visual.zooms(items, words: words, rule: PunchInRule(zoom: 1.12, minSpacing: 4, maxStill: 0))
        #expect(out.items[0].transform.zoom.isAnimated)
        #expect(out.items[1].transform.zoom == items[1].transform.zoom)
        #expect(out.note == "Added 1 zoom (1 on emphasis, 0 for pacing)")
    }
}
