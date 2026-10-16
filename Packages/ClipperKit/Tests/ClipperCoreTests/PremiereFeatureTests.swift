import Foundation
import Testing
@testable import ClipperCore

@Suite struct EditingModelTests {
    @Test func newFieldsAreOmittedWhenDefaultAndRoundTrip() throws {
        let plain = Item(range: TimeRange(seconds: 0, 1), content: .solid(.black))
        let json = String(decoding: try ClipperJSON.encode(plain), as: UTF8.self)
        for key in ["enabled", "color", "blend", "transition", "flipH", "flipV"] { #expect(!json.contains("\"\(key)\""), "\(key) written by default") }

        var edited = plain
        edited.enabled = false
        edited.color = ColorAdjust(exposure: 0.5, saturation: -1)
        edited.blend = .screen
        edited.transition = Transition(.dipToWhite, duration: RationalTime(seconds: 0.5))
        edited.transform.flipH = true
        let back = try ClipperJSON.decode(Item.self, from: ClipperJSON.encode(edited))
        #expect(back == edited)

        var tl = Timeline(name: "T", canvas: .vertical1080, tracks: [Track(kind: .video, items: [edited])])
        #expect(!String(decoding: try ClipperJSON.encode(tl), as: UTF8.self).contains("\"markers\""))
        tl.markers = [Marker(time: RationalTime(seconds: 2), name: "Hook")]
        #expect(try ClipperJSON.decode(Timeline.self, from: ClipperJSON.encode(tl)) == tl)
    }

    @Test func documentsFromBeforeTheseFieldsStillLoad() throws {
        // An item and transform exactly as version-1 documents stored them.
        let old = Data(##"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"A","range":{"start":0,"duration":1},"content":{"type":"solid","solid":"#000000"},"transform":{"box":{"width":1,"height":1},"position":{"x":0.5,"y":0.5},"scale":1,"rotation":0,"zoom":1,"focus":{"x":0.5,"y":0.5},"crop":{"x":0,"y":0,"width":1,"height":1},"fit":"fill"},"opacity":1,"gain":0,"fadeIn":0,"fadeOut":0,"origin":"user","locked":false}"##.utf8)
        let item = try ClipperJSON.decode(Item.self, from: old)
        #expect(item.enabled && item.color.isNone && item.blend == .normal && item.transition == nil && !item.transform.flipH)
    }
}

@Suite struct FrameAndAudioTests {
    @Test func changingTheFrameKeepsLayout() throws {
        let (tl, asset, _, _, _, _) = makeTimeline()
        let out = try ChangeCanvas(.landscape1080).apply(to: tl, context: ctx(asset))
        #expect(out.canvas == .landscape1080 && out.tracks == tl.tracks)
        #expect(throws: EditError.nothingToDo) { try ChangeCanvas(.vertical1080).apply(to: tl, context: ctx(asset)) }
        #expect(throws: EditError.invalidRange("frame 1081×1920")) { try ChangeCanvas(Canvas(width: 1081, height: 1920)).apply(to: tl, context: ctx(asset)) }
    }

    @Test func detachingAudioMakesALinkedAudioItem() throws {
        var (tl, asset, a, _, video, _) = makeTimeline()
        tl.tracks[0].items[0].fadeIn = RationalTime(seconds: 0.5)
        let audioID = UUID()
        let out = try DetachAudio(a, audioID: audioID).apply(to: tl, context: ctx(asset))
        #expect(out.item(a)?.content.mediaRef?.useAudio == false)
        let audio = try #require(out.item(audioID))
        #expect(audio.range == tl.tracks[0].items[0].range && audio.content.mediaRef?.useAudio == true && audio.fadeIn == RationalTime(seconds: 0.5))
        #expect(out.tracks.first { $0.items.contains { $0.id == audioID } }?.kind == .audio)
        #expect(throws: EditError.nothingToDo) { try DetachAudio(a).apply(to: out, context: ctx(asset)) }   // already silent
        _ = video
    }
}

@Suite struct ApplyStyleTests {
    @Test func appliesToEveryCaptionButNotLockedOnes() throws {
        let page = { (s: Double, style: String) in
            Item(range: TimeRange(seconds: s, s + 1), content: .caption(CaptionContent(words: [.init(text: "x", start: .zero, end: RationalTime(seconds: 0.5))], style: style)))
        }
        var locked = page(2, "a")
        locked.locked = true
        let tl = Timeline(name: "T", canvas: .vertical1080, tracks: [Track(kind: .caption, items: [page(0, "a"), page(1, "b"), locked])],
                          styles: ["a": TextStyle(), "b": TextStyle(position: NormPoint(0.5, 0.3))])
        let out = try ApplyStyleToAll(.captions, style: "b").apply(to: tl, context: EditContext())
        let styles = out.tracks[0].items.map { if case .caption(let c) = $0.content { c.style } else { "" } }
        #expect(styles == ["b", "b", "a"])
        #expect(out.tracks[0].items[0].transform.position == .constant(NormPoint(0.5, 0.3)))
        #expect(throws: EditError.nothingToDo) { try ApplyStyleToAll(.text, style: "b").apply(to: tl, context: EditContext()) }
    }

    @Test func markersViaModifyTimeline() throws {
        let tl = Timeline(name: "T", canvas: .vertical1080)
        let out = try ModifyTimeline(name: "Add Marker") { $0.markers.append(Marker(time: RationalTime(seconds: 1))) }.apply(to: tl, context: EditContext())
        #expect(out.markers.count == 1)
    }
}
