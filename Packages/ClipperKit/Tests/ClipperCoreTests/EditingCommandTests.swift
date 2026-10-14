import Foundation
import Testing
@testable import ClipperCore

/// Video [0,4) [4,10), a title track, a caption track with one page [0,10) and a music track [0,10).
private func richTimeline() -> (Timeline, asset: AssetID, video: TrackID, titles: TrackID, captions: TrackID, music: TrackID) {
    var (tl, asset, _, _, video, titles) = makeTimeline()
    let words = (0..<10).map { CaptionContent.Word(text: "w\($0)", start: RationalTime(seconds: Double($0)), end: RationalTime(seconds: Double($0) + 0.8)) }
    let caption = Track(kind: .caption, items: [Item(name: "Cap", range: TimeRange(seconds: 0, 10), content: .caption(CaptionContent(words: words, style: "s")))])
    let music = Track(kind: .music, items: [Item(name: "Song", range: TimeRange(seconds: 0, 10),
                                                  content: .media(MediaRef(asset: asset, source: TimeRange(seconds: 0, 10))))])
    tl.tracks += [caption, music]
    return (tl, asset, video, titles, caption.id, music.id)
}

private func sec(_ s: Double) -> RationalTime { RationalTime(seconds: s) }

@Suite struct PlaceItemsTests {
    @Test func usesThePreferredTrackWhenFreeOtherwiseAnotherOrANewOne() throws {
        let (tl, asset, _, titles, _, _) = richTimeline()
        let a = Item(name: "T1", range: TimeRange(seconds: 1, 3), content: .text(TextContent(text: "Hi", style: "s")))
        var out = try PlaceItems([.init(a, track: titles, kinds: [.title])]).apply(to: tl, context: ctx(asset))
        #expect(out.tracks.first { $0.id == titles }?.items.map(\.name) == ["T1"])

        // Same span again: the title track is taken, so a second title track is created — below the captions.
        let b = Item(name: "T2", range: TimeRange(seconds: 2, 4), content: .text(TextContent(text: "Yo", style: "s")))
        out = try PlaceItems([.init(b, track: titles, kinds: [.title])]).apply(to: out, context: ctx(asset))
        let titleTracks = out.tracks.filter { $0.kind == .title }
        #expect(titleTracks.count == 2 && titleTracks[1].name == "Title 2" && titleTracks[1].items.map(\.name) == ["T2"])
        let newIndex = try #require(out.trackIndex(titleTracks[1].id)), captionIndex = try #require(out.tracks.firstIndex { $0.kind == .caption })
        #expect(newIndex < captionIndex)
        #expect(out.validate().filter { $0.severity == .error }.isEmpty)
    }

    @Test func newOverlayTracksSitBelowTitles() throws {
        let (tl, asset, _, _, _, _) = richTimeline()
        let clip = Item(name: "B-roll", range: TimeRange(seconds: 2, 5), content: .media(MediaRef(asset: asset, source: TimeRange(seconds: 0, 3))))
        let out = try PlaceItems([.init(clip, kinds: [.overlay, .video])]).apply(to: tl, context: ctx(asset))
        let i = try #require(out.tracks.firstIndex { $0.kind == .overlay })
        #expect(i == 1)   // above the video, under the title track
        #expect(out.tracks[i].items.map(\.name) == ["B-roll"])
    }

    @Test func lockedTracksAreSkipped() throws {
        var (tl, asset, _, titles, _, _) = richTimeline()
        tl.tracks[tl.trackIndex(titles)!].locked = true
        let a = Item(name: "T", range: TimeRange(seconds: 0, 1), content: .text(TextContent(text: "x", style: "s")))
        let out = try PlaceItems([.init(a, track: titles, kinds: [.title])]).apply(to: tl, context: ctx(asset))
        #expect(out.tracks.first { $0.id == titles }?.items.isEmpty == true)
        #expect(out.tracks.filter { $0.kind == .title }.count == 2)
    }
}

@Suite struct InsertEditTests {
    @Test func opensAGapOnEveryTrackSoEverythingStaysInSync() throws {
        let (tl, asset, video, _, captions, music) = richTimeline()
        let clip = Item(name: "New", range: TimeRange(seconds: 2, 5), content: .media(MediaRef(asset: asset, source: TimeRange(seconds: 30, 33))))
        let out = try InsertEdit(clip, on: video).apply(to: tl, context: ctx(asset))
        let v = out.tracks.first { $0.id == video }!.items
        #expect(v.map(\.name) == ["A", "New", "A", "B"])
        #expect(v.map(\.range) == [TimeRange(seconds: 0, 2), TimeRange(seconds: 2, 5), TimeRange(seconds: 5, 7), TimeRange(seconds: 7, 13)])
        #expect(v[2].content.mediaRef?.source == TimeRange(seconds: 12, 14))   // the tail continues where the head stopped
        let m = out.tracks.first { $0.id == music }!.items
        #expect(m.map(\.range) == [TimeRange(seconds: 0, 2), TimeRange(seconds: 5, 13)])
        // The caption page splits too, each half keeping only its own words.
        let c = out.tracks.first { $0.id == captions }!.items
        guard case .caption(let head) = c[0].content, case .caption(let tail) = c[1].content else { Issue.record("captions"); return }
        #expect(head.words.map(\.text) == ["w0", "w1"])
        #expect(tail.words.first?.text == "w2" && tail.words.first?.start == .zero && tail.words.count == 8)
        #expect(out.validate(assetDurations: [asset: sec(60)]).filter { $0.severity == .error }.isEmpty)
        #expect(out.duration == sec(13))
    }

    @Test func lockedTracksDontMoveAndLockedSpanningItemsRefuse() throws {
        var (tl, asset, video, _, _, music) = richTimeline()
        tl.tracks[tl.trackIndex(music)!].locked = true
        let clip = Item(name: "New", range: TimeRange(seconds: 2, 3), content: .media(MediaRef(asset: asset, source: TimeRange(seconds: 30, 31))))
        let out = try InsertEdit(clip, on: video).apply(to: tl, context: ctx(asset))
        #expect(out.tracks.first { $0.id == music }!.items.map(\.range) == [TimeRange(seconds: 0, 10)])

        var locked = richTimeline().0
        locked.tracks[0].items[0].locked = true
        #expect(throws: EditError.itemLocked(locked.tracks[0].items[0].id)) {
            try InsertEdit(clip, on: locked.tracks[0].id).apply(to: locked, context: ctx(asset))
        }
    }
}

@Suite struct RemoveRangeTests {
    @Test func extractClosesTheGapOnAllTracks() throws {
        let (tl, asset, video, _, captions, music) = richTimeline()
        let out = try RemoveRange(TimeRange(seconds: 3, 5), ripple: true).apply(to: tl, context: ctx(asset))
        let v = out.tracks.first { $0.id == video }!.items
        #expect(v.map(\.range) == [TimeRange(seconds: 0, 3), TimeRange(seconds: 3, 8)])
        #expect(v[1].content.mediaRef?.source == TimeRange(seconds: 21, 26))
        #expect(out.tracks.first { $0.id == music }!.items.map(\.range) == [TimeRange(seconds: 0, 3), TimeRange(seconds: 3, 8)])
        let c = out.tracks.first { $0.id == captions }!.items
        guard case .caption(let tail) = c[1].content else { Issue.record("caption"); return }
        #expect(tail.words.first?.text == "w5")
        #expect(out.duration == sec(8))
        #expect(out.validate(assetDurations: [asset: sec(60)]).filter { $0.severity == .error }.isEmpty)
    }

    @Test func liftLeavesAGap() throws {
        let (tl, asset, video, _, _, _) = richTimeline()
        let out = try RemoveRange(TimeRange(seconds: 3, 5), ripple: false).apply(to: tl, context: ctx(asset))
        #expect(out.tracks.first { $0.id == video }!.items.map(\.range) == [TimeRange(seconds: 0, 3), TimeRange(seconds: 5, 10)])
        #expect(out.duration == sec(10))
        #expect(throws: EditError.nothingToDo) { try RemoveRange(TimeRange(seconds: 20, 21), ripple: false).apply(to: tl, context: ctx(asset)) }
    }
}

@Suite struct NudgeAndSpeedTests {
    @Test func nudgeMovesAndRejectsCollisions() throws {
        var (tl, asset, video, titles, _, _) = richTimeline()
        let t = Item(name: "T", range: TimeRange(seconds: 1, 2), content: .text(TextContent(text: "x", style: "s")))
        tl = try InsertItem(t, on: titles).apply(to: tl, context: ctx(asset))
        let frame = tl.canvas.frameRate.frameDuration
        let out = try NudgeItems([t.id], by: frame).apply(to: tl, context: ctx(asset))
        #expect(out.item(t.id)?.start == sec(1) + frame)
        #expect(NudgeItems([t.id], by: frame).coalescingKey == NudgeItems([t.id], by: -frame).coalescingKey)
        let a = tl.tracks.first { $0.id == video }!.items[0].id
        #expect(throws: EditError.overlap(video)) { try NudgeItems([a], by: frame).apply(to: tl, context: ctx(asset)) }
        #expect(throws: EditError.invalidRange("before timeline start")) { try NudgeItems([a], by: -frame).apply(to: tl, context: ctx(asset)) }
    }

    @Test func speedChangesLengthKeyframesAndRipples() throws {
        let (tl, asset, video, _, _, _) = richTimeline()
        let a = tl.tracks[0].items[0]          // [0,4) from source [10,14), opacity keys at 1 s and 2 s
        let fast = try SetSpeed(a.id, speed: 2, ripple: true).apply(to: tl, context: ctx(asset))
        let v = fast.tracks.first { $0.id == video }!.items
        #expect(v[0].range == TimeRange(seconds: 0, 2))
        #expect(v[0].content.mediaRef?.source == TimeRange(seconds: 10, 14) && v[0].content.mediaRef?.speed == 2)
        #expect(v[0].opacity.keys.map(\.time) == [sec(0.5), sec(1)])
        #expect(v[1].range == TimeRange(seconds: 2, 8))     // B followed
        #expect(fast.validate(assetDurations: [asset: sec(60)]).filter { $0.severity == .error }.isEmpty)

        // Slowing down without ripple would run into B.
        #expect(throws: EditError.overlap(video)) { try SetSpeed(a.id, speed: 0.5, ripple: false).apply(to: tl, context: ctx(asset)) }
        let slow = try SetSpeed(a.id, speed: 0.5, ripple: true).apply(to: tl, context: ctx(asset))
        #expect(slow.tracks[0].items.map(\.range) == [TimeRange(seconds: 0, 8), TimeRange(seconds: 8, 14)])

        // Odd speeds land on whole frames and never use more source than before.
        let odd = try SetSpeed(a.id, speed: 3, ripple: true).apply(to: tl, context: ctx(asset))
        let i = odd.tracks[0].items[0]
        #expect(i.range.duration == i.range.duration.floorToFrame(odd.canvas.frameRate))
        #expect(i.content.mediaRef!.source.duration <= sec(4))
        #expect(odd.validate(assetDurations: [asset: sec(60)]).filter { $0.severity == .error }.isEmpty)
        #expect(throws: EditError.invalidRange("speed 20.0 outside 0.1×–16×")) { try SetSpeed(a.id, speed: 20, ripple: true).apply(to: tl, context: ctx(asset)) }
    }
}

@Suite struct CaptionTrimTests {
    @Test func bladingACaptionKeepsEachWordOnOneSide() throws {
        let (tl, asset, _, _, captions, _) = richTimeline()
        let out = try Blade(at: sec(4.5), tracks: [captions]).apply(to: tl, context: ctx(asset))
        let c = out.tracks.first { $0.id == captions }!.items
        guard case .caption(let a) = c[0].content, case .caption(let b) = c[1].content else { Issue.record("captions"); return }
        #expect(a.words.map(\.text) == ["w0", "w1", "w2", "w3", "w4"])   // w4 is 4.0–4.8: midpoint 4.4 < 4.5
        #expect(b.words.map(\.text) == ["w5", "w6", "w7", "w8", "w9"])
        #expect(a.words.last?.end == sec(4.5))                            // clamped to the cut
    }
}

@Suite struct BatchTests {
    @Test func appliesInOrderAndFailsAsAWhole() throws {
        let (tl, asset, _, titles, _, _) = richTimeline()
        let t = Item(name: "T", range: TimeRange(seconds: 0, 1), content: .text(TextContent(text: "x", style: "new")))
        let ok = try Batch([SetStyle("new", TextStyle(size: 0.08)), InsertItem(t, on: titles)], name: "Add Text").apply(to: tl, context: ctx(asset))
        #expect(ok.styles["new"]?.size == 0.08 && ok.item(t.id) != nil)
        #expect(throws: EditError.overlap(titles)) {
            let u = Item(name: "U", range: TimeRange(seconds: 0.5, 2), content: .text(TextContent(text: "y", style: "new")))
            return try Batch([InsertItem(t, on: titles), InsertItem(u, on: titles)], name: "x").apply(to: tl, context: ctx(asset))
        }
    }
}
