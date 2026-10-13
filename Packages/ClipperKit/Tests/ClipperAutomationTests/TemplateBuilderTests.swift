import ClipperCore
import Foundation
import Testing
@testable import ClipperAutomation

@Suite struct TemplateBuilderTests {
    /// Structural signature of a timeline: tracks (kind/name) and item placement, ignoring ids.
    func shape(_ tl: Timeline) -> [String] {
        tl.tracks.map { t in "\(t.kind.rawValue):\(t.name):" + t.items.map { "\($0.start)-\($0.end)" }.joined(separator: ",") }
    }

    func draft(_ template: Template, clips: [ClipInput], title: String? = "My title") -> Timeline {
        DraftPipeline.run(DraftInput(template: template, clips: clips,
                                     music: [music("chill", bpm: 96, seconds: 120, moods: ["chill", "upbeat", "energetic", "inspiring"])],
                                     settings: DraftSettings(title: title, seed: 3))).timeline
    }

    @Test func talkingHeadRoundTrips() {
        let input = talkingInput()
        let tl = draft(BuiltIns.talkingHead, clips: input.clips)
        let r = TemplateBuilder.make(from: tl, id: "my-talk", name: "My Talk", basedOn: BuiltIns.talkingHead)
        let t = r.template
        #expect(TemplateValidator.validate(t).isEmpty, "\(TemplateValidator.validate(t))")
        #expect(t.slots.count == 1 && t.slots[0].id == "speaker" && t.slots[0].role == .primary && t.slots[0].fill == .sequence)
        #expect(t.slots[0].transform == .fullFrame)                       // punch-ins/reframes stripped
        #expect(t.slots[0].reframe == .face)
        #expect(t.rules.captions?.style == "bold-pop")
        #expect(t.rules.silenceCut == BuiltIns.talkingHead.rules.silenceCut)
        #expect(t.rules.punchIn != nil && t.rules.duck != nil)
        #expect(t.music.enabled && t.music.gain == BuiltIns.talkingHead.music.gain)
        #expect(t.elements.count == 1)
        if case .text(let text) = t.elements[0].content { #expect(text.text == "{title}") } else { Issue.record("title element missing") }
        #expect(t.elements[0].timing == .opening(seconds: 2.5))
        #expect(t.styles["bold-pop"] != nil && t.styles["title-bold"] != nil)
        // Drafting again from the saved template gives the same structure.
        let again = draft(t, clips: input.clips)
        #expect(shape(again) == shape(tl))
        // And it survives JSON.
        #expect(TemplateValidator.decode(try! ClipperJSON.encode(t)).0 == t)
    }

    @Test func gameplayFacecamIsLinked() {
        let game = videoAsset("game", seconds: 40)
        let cam = videoAsset("cam", seconds: 40, width: 1280, height: 720, audio: false)
        let tr = transcript(speech, pauses: [0.3, 2, 0.4, 3])
        let tl = draft(BuiltIns.gameplay, clips: [ClipInput(asset: game, analysis: AssetAnalysis(transcript: tr)), ClipInput(asset: cam, slot: "facecam")])
        let t = TemplateBuilder.make(from: tl, id: "my-game", name: "My Game", basedOn: BuiltIns.gameplay).template
        let cs = t.slots.first { $0.id == "facecam" }
        #expect(cs?.fill == .linked && cs?.role == .secondary && cs?.useAudio == false)
        #expect(t.slots.first { $0.id == "gameplay" }?.transform.box == NormSize(1, 0.6))
        #expect(t.slots.first { $0.id == "gameplay" }?.aloneTransform == .fullFrame)
        #expect(t.rules.captions?.style == "gameplay-caption" && t.styles["gameplay-caption"] != nil)
    }

    @Test func userEditsBecomePartOfTheTemplate() {
        let input = talkingInput()
        var tl = draft(BuiltIns.talkingHead, clips: input.clips)
        // The user adds a branding watermark for the whole video and turns captions off.
        var mark = Item(name: "Watermark", range: TimeRange(start: .zero, duration: tl.duration),
                        content: .text(TextContent(text: "@yash", style: "title-clean")))
        mark.transform.position = .constant(NormPoint(0.85, 0.95))
        tl.tracks.append(Track(kind: .overlay, name: "Branding", items: [mark]))
        tl.tracks.removeAll { $0.kind == .caption }
        let r = TemplateBuilder.make(from: tl, id: "branded", name: "Branded")
        let t = r.template
        let wm = t.elements.first { $0.id == "watermark" }
        #expect(wm?.timing == .whole && wm?.track == .overlay)
        #expect(wm?.transform.position == .constant(NormPoint(0.85, 0.95)))
        if case .text(let text) = wm?.content { #expect(text.text == "@yash") }
        #expect(t.rules.captions == nil)
        #expect(t.contentType == .custom && t.exportPreset == "shorts-1080x1920")
        // A new draft carries the watermark.
        let again = draft(t, clips: input.clips)
        #expect(again.allItems.contains { if case .text(let x) = $0.content { x.text == "@yash" } else { false } })
    }

    @Test func validatorAndReadableDecodeErrors() {
        var t = BuiltIns.talkingHead
        t.id = "Bad ID"
        t.slots.append(Slot(id: "speaker", name: "dup", role: .primary))
        t.rules.captions = CaptionRule(style: "nope")
        t.music.moods = ["jazzy"]
        let issues = TemplateValidator.validate(t)
        #expect(issues.count >= 4, "\(issues)")
        let bad = Data(#"{"id":"x","version":1,"name":"x","summary":"","contentType":"custom","canvas":{"width":1080,"height":1920,"frameRate":{"numerator":30,"denominator":1}},"slots":[{"id":"a","name":"A","role":"primary","fill":"loops"}]}"#.utf8)
        let (decoded, errors) = TemplateValidator.decode(bad)
        #expect(decoded == nil)
        #expect(errors.first?.contains("slots[0]") == true, "\(errors)")
    }
}

@Suite struct TemplateBuilderMixedSlotTests {
    @Test func manualClipWithoutSlotFirstOnTheTrackKeepsTheSlot() throws {
        // The user put a manual clip (no slot) first on the primary track, before the draft's clips.
        var tl = DraftPipeline.run(talkingInput()).timeline
        let index = try #require(tl.tracks.firstIndex { t in t.items.contains { $0.slot == "speaker" } })
        let manualAsset = videoAsset("manual", seconds: 5)
        let manual = Item(range: TimeRange(seconds: tl.duration.seconds, tl.duration.seconds + 2),
                          content: .media(MediaRef(asset: manualAsset.id, source: TimeRange(seconds: 0, 2))))
        tl.tracks[index].items.insert(manual, at: 0)
        #expect(tl.tracks[index].items[0].slot == nil)

        let t = TemplateBuilder.make(from: tl, id: "mixed", name: "Mixed", basedOn: BuiltIns.talkingHead).template
        #expect(t.slots.contains { $0.id == "speaker" && $0.role == .primary })
    }
}
