import ClipperCore
import Foundation
import Testing
@testable import ClipperAutomation

@Suite struct BRollTests {
    @Test(arguments: [
        ("Camera B-roll 2.mov", ["camera"]),
        ("editor-screen", ["editor", "screen"]),
        ("final_clips_v3 take2", []),
        ("Glass cups", ["glass", "cup"]),
        ("MacDesk", ["macdesk"]),
    ])
    func namesBecomeTokens(name: String, tokens: [String]) {
        #expect(BRoll.tokens(name) == tokens)
    }

    @Test(arguments: [
        ("camera", ["camera"], 2.0),
        ("Cameras", ["camera"], 2.0),
        ("photograph", ["photo"], 1.0),
        ("cardboard", ["card"], nil),
        ("camera", ["cam", "screen"], nil),
        ("desk", ["mac"], nil),
    ] as [(String, Set<String>, Double?)])
    func keywordsMatchTokens(lemma: String, tokens: Set<String>, strength: Double?) {
        #expect(BRoll.strength(lemma, tokens) == strength)
    }

    @Test func tagsAndSpokenKeywordsCountAsTokens() {
        var asset = videoAsset("IMG_0042", seconds: 8)
        asset.tags = ["b-roll", "Coffee shop"]
        let spoken = AssetAnalysis(keywords: KeywordTags(tags: [.init(word: 0, kind: .noun, lemma: "espresso"),
                                                                .init(word: 1, kind: .emphasis, lemma: "wow")]))
        #expect(BRoll.tokens(of: ClipInput(asset: asset, analysis: spoken)) == ["img", "coffee", "shop", "espresso"])
        let silent = videoAsset("IMG_0042", seconds: 8, audio: false)
        #expect(BRoll.tokens(of: ClipInput(asset: silent, analysis: spoken)) == ["img"])
    }

    @Test func libraryBRollIsMarkedByTagOrName() {
        var tagged = videoAsset("clip", seconds: 3)
        tagged.tags = ["B-Roll"]
        #expect(tagged.isBRoll)
        #expect(videoAsset("Camera B-roll 2", seconds: 3).isBRoll)
        #expect(videoAsset("desk_broll", seconds: 3).isBRoll)
        #expect(!videoAsset("brollywood", seconds: 3).isBRoll)
    }

    func word(_ text: String, at t: Double, lemma: String? = nil) -> TimedWord {
        TimedWord(text: text, start: t, end: t + 0.3, isFiller: false, lemma: lemma)
    }

    @Test func placementKeepsOffTheHookAndUnderThePerMinuteCap() {
        let clip = ClipInput(asset: videoAsset("camera", seconds: 20, audio: false))
        let words = [3.0, 10, 17, 24, 31].map { word("camera", at: $0, lemma: "camera") }
        var ids = IDGenerator(seed: 1)
        let capped = BRoll.place([clip], words: words, keep: [], rule: BRollRule(maxPerMinute: 2), slot: BuiltIns.broll,
                                 duration: 40, rate: .fps30, ids: &ids)
        #expect(capped.items.map { $0.start } == [RationalTime.frames(2.85, .fps30), RationalTime.frames(9.85, .fps30)])
        let hooked = BRoll.place([clip], words: [words[0]], keep: [word("this", at: 3.5)], rule: BRollRule(), slot: BuiltIns.broll,
                                 duration: 40, rate: .fps30, ids: &ids)
        #expect(hooked.items.isEmpty && hooked.matched)
        #expect(hooked.warning?.contains("the hook") == true)
    }

    /// A speaker naming their camera four times, the first inside the title and the third too soon after the second; `camera` words are tagged nouns.
    func cameraInput(candidates: [ClipInput]) -> DraftInput {
        let tr = transcript([
            "My camera sits right here.",
            "Every morning I check the light and the sound before recording anything at all.",
            "This camera handles low light really well.",
            "Then the camera again.",
            "We will talk about editing and color and audio and export settings and pacing later on.",
            "Finally the camera survives every trip I take.",
            "Thanks for watching and see you next time.",
        ], pauses: [0.5, 0.5, 0.5, 0.5, 0.5, 0.5])
        let tags = tr.words.indices.filter { tr.words[$0].text.lowercased().hasPrefix("camera") }
            .map { KeywordTags.Tag(word: $0, kind: .noun, lemma: "camera") }
        let speaker = ClipInput(asset: videoAsset("speaker", seconds: 40), analysis: AssetAnalysis(transcript: tr, keywords: KeywordTags(tags: tags)))
        return DraftInput(template: BuiltIns.talkingHead, clips: [speaker] + candidates, settings: DraftSettings(seed: 3))
    }

    @Test func aSpokenCameraCutsAwayToTheCameraClip() throws {
        let broll = ClipInput(asset: videoAsset("Camera B-roll 2", seconds: 10), slot: "broll")
        let other = ClipInput(asset: videoAsset("desk", seconds: 10), slot: "broll")
        let input = cameraInput(candidates: [other, broll])
        let r = DraftPipeline.run(input)
        let track = try #require(r.timeline.tracks.first { $0.name == "B-roll" })
        #expect(track.kind == .overlay)
        #expect(r.timeline.tracks.firstIndex { $0.name == "B-roll" }! < r.timeline.tracks.firstIndex { $0.kind == .caption }!)
        #expect(r.report.notes.contains("Added 2 B-roll cutaways (Camera B-roll 2)"))
        let starts = track.items.map(\.start.seconds)
        try #require(starts.count == 2)
        #expect(starts[0] >= 2.5 && starts[1] - starts[0] >= BRollRule().minSpacing)
        for item in track.items {
            let ref = try #require(item.content.mediaRef)
            #expect(ref.asset == broll.asset.id && !ref.useAudio && item.origin == .auto(pass: "broll") && item.slot == "broll")
            #expect(abs(item.range.duration.seconds - 2.5) < 0.05)
            // Under the cutaway's lead-in, the speaker is saying "camera".
            let t = item.start + RationalTime.frames(0.15, .fps30)
            let primary = try #require(r.timeline.tracks[0].items.first { $0.range.contains(t) })
            let source = primary.content.mediaRef!.source.start.seconds + (t - primary.start).seconds
            let said = input.clips[0].analysis.transcript!.words.first { abs($0.start - source) < 0.05 }
            #expect(said?.text.lowercased().hasPrefix("camera") == true)
        }
        let sources = track.items.map { $0.content.mediaRef!.source }
        #expect(sources[1].start == sources[0].end)
        #expect(DraftPipeline.run(input).timeline == r.timeline)
    }

    @Test func noCandidatesNoTrackAndNoMatchWarns() {
        let none = DraftPipeline.run(cameraInput(candidates: []))
        #expect(!none.timeline.tracks.contains { $0.name == "B-roll" })
        #expect(!none.report.warnings.contains { $0.hasPrefix("B-roll") })
        let unmatched = DraftPipeline.run(cameraInput(candidates: [ClipInput(asset: videoAsset("sunset", seconds: 5), slot: "broll")]))
        #expect(!unmatched.timeline.tracks.contains { $0.name == "B-roll" })
        #expect(unmatched.report.warnings.contains("B-roll: no clip name or tag matched a spoken keyword"))
    }
}
