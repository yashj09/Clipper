import ClipperCore
import Foundation
import Testing
@testable import ClipperAutomation

let darkClip = ColorStats(luma: 0.2, p01: 0.02, p99: 0.45, saturation: 0.3, r: 0.2, g: 0.2, b: 0.2)
let balancedClip = ColorStats(luma: 0.45, p01: 0.05, p99: 0.95, saturation: 0.35, r: 0.45, g: 0.45, b: 0.45)

func mediaItems(_ t: Timeline) -> [Item] {
    t.tracks.filter { $0.kind == .video || $0.kind == .overlay }.flatMap(\.items).filter { $0.content.mediaRef != nil }
}

@Suite struct ColourTests {
    @Test func aDarkClipIsBrightenedOnEveryItem() throws {
        var input = talkingInput()
        input.clips[0].analysis.color = darkClip
        let result = DraftPipeline.run(input)
        let items = mediaItems(result.timeline)
        #expect(items.count > 1)
        #expect(items.allSatisfy { $0.color == ColorAdjust.suggested(for: darkClip) && $0.color.exposure > 0 })
        #expect(result.report.notes.contains("Colour-matched 1 clip"))
    }

    @Test func aBalancedClipOrNoStatsChangesNothing() {
        var input = talkingInput()
        input.clips[0].analysis.color = balancedClip
        let balanced = DraftPipeline.run(input)
        #expect(mediaItems(balanced.timeline).allSatisfy { $0.color.isNone })
        #expect(!balanced.report.notes.contains { $0.hasPrefix("Colour-matched") })
        input.clips[0].analysis.color = nil
        #expect(DraftPipeline.run(input).timeline == balanced.timeline)
    }

    @Test func gameplayIsLeftUngraded() {
        var input = talkingInput()
        input.template = BuiltIns.gameplay
        input.clips[0].analysis.color = darkClip
        let t = DraftPipeline.run(input).timeline
        #expect(!mediaItems(t).isEmpty)
        #expect(mediaItems(t).allSatisfy { $0.color.isNone })
        #expect(!DraftPipeline.analysisKinds(for: BuiltIns.gameplay).contains(.color))
        #expect(DraftPipeline.analysisKinds(for: BuiltIns.talkingHead).contains(.color))
    }
}

func montageInput(clips: Int = 3, seconds: Double = 12) -> DraftInput {
    let assets = (0..<clips).map { videoAsset("shot\($0)", seconds: seconds, audio: false) }
    return DraftInput(template: BuiltIns.montage, clips: assets.map { ClipInput(asset: $0) },
                      music: [music("beat", bpm: 120, seconds: 60, moods: ["upbeat"])], settings: DraftSettings(seed: 3))
}

@Suite struct TransitionTests {
    @Test func vlogChaptersDipToBlackOnTheirItems() throws {
        // A 2 s pause before "Timing" is cut too, so both chapters start on a cut.
        let spoken = transcript(briefSpeech, pauses: [0.2, 1.6, 2, 2.5])
        let words = spoken.words
        let brief = TranscriptBrief(model: "m", chapters: [
            .init(start: words[0].start, title: "Intro"), .init(start: words[19].start, title: "No cloud"),
            .init(start: words[28].start, title: "Timing"),
        ])
        var input = briefedInput(brief, template: BuiltIns.vlog)
        input.clips[0].analysis.transcript = spoken
        let result = DraftPipeline.run(input)
        let t = result.timeline
        let items = t.tracks[0].items
        let dipped = items.filter { $0.transition != nil }
        #expect(dipped.count == 2)
        #expect(dipped.allSatisfy { $0.transition == Transition(.dipToBlack, duration: RationalTime(value: 12, scale: 30)) })
        for name in ["Chapter: No cloud", "Chapter: Timing"] {
            let marker = try #require(t.markers.first { $0.name == name })
            #expect(dipped.contains { (marker.time - $0.start).seconds > 0 && (marker.time - $0.start).seconds < 0.2 })
        }
        #expect(items[0].transition == nil)
        #expect(result.report.notes.contains("Added 2 transitions"))
        var off = input
        off.template.rules.transitions = nil
        #expect(DraftPipeline.run(off).timeline.tracks[0].items.allSatisfy { $0.transition == nil })
    }

    @Test func montageDissolvesEveryFourthCutAndNeverTwoInARow() {
        let result = DraftPipeline.run(montageInput())
        let items = result.timeline.tracks[0].items
        #expect(items.count >= 12)
        let dissolved = items.indices.filter { items[$0].transition != nil }
        #expect(dissolved == Array(stride(from: 4, to: items.count, by: 4)).filter { items[$0].range.duration.seconds >= 0.6 })
        #expect(items.allSatisfy { $0.transition.map { $0.kind == .crossDissolve && $0.duration == RationalTime(value: 9, scale: 30) } ?? true })
        #expect(!zip(dissolved, dissolved.dropFirst()).contains { $1 - $0 == 1 })
        #expect(result.report.notes.contains("Added \(dissolved.count) transitions"))
    }

    @Test func dissolvesSkipShortItemsAndNeverFollowATransition() {
        let rate = FrameRate.fps30
        func item(_ start: Double, _ end: Double) -> Item {
            Item(range: TimeRange(start: .frames(start, rate), end: .frames(end, rate)), content: .solid(.white))
        }
        let items = [item(0, 2), item(2, 4), item(4, 4.4), item(4.4, 6.4), item(6.4, 8.4)]
        let rule = TransitionRule(chapters: nil, montageEvery: 2)
        let out = Visual.transitions(items, cuts: [2, 4, 4.4, 6.4], chapters: [], rule: rule, rate: rate).items
        // The second cut's item is 0.4 s, under twice 0.3 s, so the dissolve slips to the third cut.
        #expect(out.map { $0.transition != nil } == [false, false, false, true, false])
    }
}
