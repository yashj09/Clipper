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
