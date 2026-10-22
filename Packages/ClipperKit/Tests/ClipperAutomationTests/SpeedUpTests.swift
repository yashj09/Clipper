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

    func vlogInput(_ sentences: [String] = speech, pauses: [Double] = [0.2, 1.0, 1.2, 2.5]) -> DraftInput {
        var input = talkingInput()
        input.template = BuiltIns.vlog
        input.clips[0].analysis.transcript = transcript(sentences, pauses: pauses)
        return input
    }

    func refs(_ r: DraftResult) -> [(item: Item, ref: MediaRef)] {
        r.timeline.tracks.first { $0.kind == .video }!.items.map { ($0, $0.content.mediaRef!) }
    }

    @Test func vlogDraftPlaysShortPausesFastWithoutAJump() {
        let input = vlogInput()
        let r = DraftPipeline.run(input)
        let durations = Dictionary(uniqueKeysWithValues: (input.clips.map(\.asset) + r.addedAssets).map { ($0.id, $0.info.duration) })
        #expect(r.timeline.validate(assetDurations: durations).filter { $0.severity == .error }.isEmpty)
        #expect(r.report.warnings.isEmpty, "\(r.report.warnings)")

        let items = refs(r)
        let fast = items.indices.filter { items[$0].ref.speed != 1 }
        // "Um" sits in the first pause and the last one is 2.5 s, so only the 1.0 s and 1.2 s pauses are kept.
        #expect(fast.count == 2)
        #expect(zip(items, items.dropFirst()).allSatisfy { $0.item.end == $1.item.start })
        for i in fast {
            let (item, ref) = items[i]
            #expect(ref.speed == 2.5)
            #expect(abs(item.range.duration.seconds - ref.source.duration.seconds / 2.5) < 0.002)
            #expect(item.origin == .auto(pass: "layout"))
            #expect(item.gain.isAnimated, "declicked like every other item")
            #expect(abs(items[i - 1].ref.source.end.seconds - ref.source.start.seconds) < 1e-6, "speech runs straight into the pause")
            #expect(abs(ref.source.end.seconds - items[i + 1].ref.source.start.seconds) < 1e-6, "the pause runs straight into speech")
        }
        #expect(r.report.notes.contains { $0.hasPrefix("Sped up 2 pauses (") && $0.hasSuffix(" at 2.5x)") }, "\(r.report.notes)")
    }

    @Test func onlyTheVlogTemplateSpeedsUpPausesAndOldRulesDecodeWithoutIt() throws {
        #expect(BuiltIns.vlog.rules.silenceCut?.speedUp == SpeedUpRule())
        #expect(BuiltIns.talkingHead.rules.silenceCut?.speedUp == nil)
        #expect(BuiltIns.gameplay.rules.silenceCut?.speedUp == nil)
        let old = #"{"minGap": 0.5, "padBefore": 0.1, "padAfter": 0.2, "removeFillers": true}"#
        #expect(try ClipperJSON.decode(SilenceCutRule.self, from: Data(old.utf8)).speedUp == nil)
        let rule = BuiltIns.vlog.rules.silenceCut!
        #expect(try ClipperJSON.decode(SilenceCutRule.self, from: ClipperJSON.encode(rule)) == rule)
        // Empty objects take the defaults, like every other rule.
        let bare = try ClipperJSON.decode(Rules.self, from: Data(#"{"beatSnap": {}, "silenceCut": {"minGap": 0.5, "padBefore": 0.1, "padAfter": 0.2, "removeFillers": true, "speedUp": {}}}"#.utf8))
        #expect(bare.beatSnap == BeatSnapRule() && bare.silenceCut?.speedUp == SpeedUpRule())
    }

    @Test func aColdOpenLeavesNoFastPauseOnEitherSideOfTheJump() throws {
        // Without a hook: pauses after sentences 1 and 2 play fast (the one after sentence 0 holds an "Um", so it is cut).
        var input = vlogInput(pauses: [1.0, 1.0, 1.0, 2.5])
        #expect(refs(DraftPipeline.run(input)).map(\.ref.speed) == [1, 1, 2.5, 1, 2.5, 1])
        // Sentence 1 as the hook: the fast pause that followed it would now run into the one after sentence 0's
        // neighbour, so it goes; the pause after sentence 2 stays fast.
        input.template.rules.hook = HookRule(maxSeconds: 10, minImportance: 0)
        input.clips[0].analysis.brief = TranscriptBrief(model: "m", hookSentence: 1)
        let r = DraftPipeline.run(input)
        #expect(r.report.notes.contains { $0.hasPrefix("Cold open") })
        let speeds = refs(r).map(\.ref.speed)
        #expect(speeds == [1, 1, 1, 2.5, 1], "\(speeds)")
        let words = input.clips[0].analysis.transcript!.words
        for w in words where !w.isFiller {
            let mid = (w.start + w.end) / 2
            #expect(refs(r).filter { $0.ref.source.start.seconds <= mid && mid < $0.ref.source.end.seconds }.count == 1, "\(w.text) plays once")
        }
    }

    @Test(arguments: stride(from: 0.1, to: 0.2, by: 0.01).map { $0 })
    func fastPauseRunningIntoTheMediaEndStaysContinuous(tail: Double) {
        var input = vlogInput(["we walked down to the beach", "then we looked out"], pauses: [1.0])
        let words = input.clips[0].analysis.transcript!.words
        // The padded speech reaches the media end, and for some tails its rounded length overshoots it.
        input.clips[0].asset = videoAsset("speaker", seconds: words.last!.end + tail)
        let items = refs(DraftPipeline.run(input))
        #expect(items.map(\.ref.speed) == [1, 2.5, 1])
        #expect(abs(items[1].ref.source.end.seconds - items[2].ref.source.start.seconds) < 1e-6)
        #expect(items[2].ref.source.end <= input.clips[0].asset.info.duration)
    }

    @Test func vlogDraftsAreDeterministic() throws {
        let a = try ClipperJSON.encode(DraftPipeline.run(vlogInput()).timeline)
        let b = try ClipperJSON.encode(DraftPipeline.run(vlogInput()).timeline)
        #expect(a == b)
    }

    @Test func fitDropsFastPausesBeforeSpeech() {
        func words(_ n: Int, at t: Double) -> [SpokenWord] {
            Array(repeating: SpokenWord(word: TranscriptWord(text: "w", start: t, end: t + 0.2), cue: []), count: n)
        }
        let segs = [Segment(clip: 0, start: 0, end: 4, words: words(10, at: 1)),
                    Segment(clip: 0, start: 4, end: 5, words: [], speed: 2.5),
                    Segment(clip: 0, start: 5, end: 9, words: words(1, at: 6))]
        var report = DraftReport()
        let out = Cutting.fit(segs, maxDuration: 8.1, report: &report)
        #expect(out == [segs[0], segs[2]])
        #expect(report.notes == ["Trimmed to 8.0s (max 8s) by dropping 1 low-density segment"])
    }

    @Test func beatSnapLeavesBothEndsOfAFastPause() {
        let clip = ClipInput(asset: videoAsset("broll", seconds: 10))
        let segs = [Segment(clip: 0, start: 0, end: 2, words: []),
                    Segment(clip: 0, start: 2, end: 3, words: [], speed: 2.5),
                    Segment(clip: 0, start: 3, end: 5, words: [])]
        let snap = Cutting.beatSnap(segs, beats: [0, 2.05, 2.45, 4.45], rule: BeatSnapRule(tolerance: 0.15), clips: [clip])
        #expect(snap.segments.map(\.end) == [2, 3, 5.05])
        #expect(snap.moved == 1)
    }

    @Test func zoomsDoNotTreatAFastPauseAsACut() {
        var input = vlogInput(["we walked down to the beach", "then we looked out at the sea"], pauses: [1.0])
        input.template.rules.punchIn = PunchInRule(zoom: 1.12, minSpacing: 4, maxStill: 0)
        let r = DraftPipeline.run(input)
        let items = refs(r).map(\.item)
        #expect(items.count == 3 && refs(r)[1].ref.speed == 2.5)
        // The sentence after the pause is cued. Were the pause's end a cut, the zoom would step there; it eases in on
        // the word instead.
        #expect(items[2].transform.zoom.value(at: .zero) == 1, "\(items.map { ($0.range, $0.transform.zoom) })")
        #expect(items[2].transform.zoom.value(at: items[2].range.duration) == 1.12)
        for (a, b) in zip(items, items.dropFirst()) {
            #expect(abs(a.transform.zoom.value(at: a.range.duration) - b.transform.zoom.value(at: .zero)) < 1e-9)
        }
        #expect(r.report.notes.contains("Added 1 zoom (1 on emphasis, 0 for pacing)"))
    }

    @Test func zoomUnderWayAtAnItemStartFinishesThere() {
        let curve = ZoomCurve(moves: [.init(start: 5.9, duration: 0.25, to: 1.12, reason: .pacing)])
        let zoom = curve.zoom(over: TimeRange(seconds: 6, 10), base: 1)
        #expect(zoom.keys.map(\.time.seconds) == [0, 0.15])
        #expect(abs(zoom.value(at: .zero) - curve.value(at: 6)) < 1e-9)
        #expect(zoom.value(at: RationalTime(seconds: 1)) == 1.12)
    }
}
