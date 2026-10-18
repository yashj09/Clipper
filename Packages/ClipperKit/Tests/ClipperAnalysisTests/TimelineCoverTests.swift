@testable import ClipperAnalysis
import ClipperCore
import Foundation
import Testing

@Suite struct TimelineCoverTests {
    @Test func prefersACaptionedFrameAndSkipsTheStartAndTransitions() {
        let asset = UUID()
        let sharp: [Double: Double] = [10: 1, 20.5: 1, 12: 0.7]
        let samples = (Array(stride(from: 10.0, to: 14, by: 0.5)) + Array(stride(from: 20.0, to: 24, by: 0.5)) + [30]).map {
            VisualSample(time: $0, change: 0, salient: nil, sharpness: sharp[$0] ?? 0.5, luma: 0.45)
        }
        var second = Item(range: TimeRange(seconds: 4, 8), content: .media(MediaRef(asset: asset, source: TimeRange(seconds: 20, 24))))
        second.transition = Transition(.crossDissolve, duration: RationalTime(seconds: 1))
        let page = Item(range: TimeRange(seconds: 6, 7), content: .caption(CaptionContent(words: [.init(text: "hi", start: .zero, end: RationalTime(seconds: 1))],
                                                                                         style: "caption")))
        let timeline = Timeline(name: "t", canvas: .vertical1080, tracks: [
            Track(kind: .video, items: [
                Item(range: TimeRange(seconds: 0, 4), content: .media(MediaRef(asset: asset, source: TimeRange(seconds: 10, 14)))), second,
            ]),
            Track(kind: .caption, items: [page]),
        ])
        let analyses = [asset: AssetAnalysis(visual: VisualActivity(samples: samples, sceneCuts: []))]

        let picked = TimelineCover.pick(timeline: timeline, analyses: analyses, count: 3)
        // 6 s (source 22 s) carries a caption; 2 s (source 12 s) is the sharpest frame left; nothing else is 2 s away
        // from both. The sharp frames at 0 s (first half second) and 4.5 s (inside the dissolve) are never picked.
        #expect(picked.map(\.time) == [6, 2])
        #expect(picked[0].reasons.contains("caption") && !picked[1].reasons.contains("caption"))
        let all = TimelineCover.pick(timeline: timeline, analyses: analyses, count: 100)
        #expect(all.allSatisfy { $0.time >= 0.5 && !(4..<5).contains($0.time) })
    }
}
