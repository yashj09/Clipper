import ClipperCore
import Foundation
import Testing
@testable import ClipperAutomation

@Suite struct RedraftTests {
    private func errors(_ tl: Timeline) -> [ValidationIssue] { tl.validate().filter { $0.severity == .error } }

    @Test func draftsRecordTheirInputs() throws {
        let input = talkingInput()
        let tl = DraftPipeline.run(input).timeline
        let record = try #require(tl.provenance?.inputs)
        #expect(record.clips == [DraftRecord.Clip(asset: input.clips[0].asset.id)])
        #expect(record.title == "Local editing in 60s")
        #expect(Redraft.record(of: tl) == record)
        // Round-trips through the document format, and old documents without it still decode.
        let decoded = try ClipperJSON.decode(Timeline.self, from: ClipperJSON.encode(tl))
        #expect(decoded.provenance?.inputs == record)
        var old = tl
        old.provenance?.inputs = nil
        #expect(try ClipperJSON.decode(Timeline.self, from: ClipperJSON.encode(old)).provenance?.inputs == nil)
    }

    @Test func olderTimelinesGetTheirInputsRebuilt() throws {
        let input = talkingInput()
        var tl = DraftPipeline.run(input).timeline
        tl.provenance?.inputs = nil
        let record = try #require(Redraft.record(of: tl))
        #expect(record.clips.map(\.asset) == [input.clips[0].asset.id])
        #expect(record.clips[0].slot == "speaker")
        let clip = record.clips[0]
        #expect(clip.inPoint! >= 0 && clip.outPoint! <= 30 && clip.inPoint! < clip.outPoint!)
        #expect(record.title == "Local editing in 60s" && record.captions == true && record.music == true)
        #expect(Redraft.record(of: Timeline(name: "x", canvas: .vertical1080)) == nil)
    }

    @Test func keepsLockedAndAddedItemsAndReplacesTheRest() throws {
        let input = talkingInput()
        var tl = DraftPipeline.run(input).timeline
        let context = EditContext()
        // The user adds a text on a new track, locks one caption page and rewrites another (unlocked) one.
        let note = Item(name: "Note", range: TimeRange(seconds: 1, 3), content: .text(TextContent(text: "Subscribe!", style: "title-clean")))
        tl = try PlaceItems([.init(note, kinds: [.title])]).apply(to: tl, context: context)
        let captionTrack = try #require(tl.tracks.firstIndex { $0.kind == .caption })
        let pages = tl.tracks[captionTrack].items
        #expect(pages.count >= 2)
        tl.tracks[captionTrack].items[0].locked = true
        if case .caption(var c) = pages[1].content { c.words[0].text = "EDITED"; tl.tracks[captionTrack].items[1].content = .caption(c) }
        let musicTrack = try #require(tl.tracks.firstIndex { $0.kind == .music })
        tl.tracks[musicTrack].muted = true

        // Re-draft with another variation and the plain caption style.
        var again = input
        again.settings.seed = 99
        let fresh = DraftPipeline.run(again).timeline
        let result = Redraft.merge(tl, into: fresh, context: context)
        let out = result.timeline

        #expect(result.kept == 2)
        #expect(out.id == tl.id && out.name == tl.name)
        #expect(out.item(note.id)?.range == note.range)
        #expect(out.item(pages[0].id)?.locked == true)
        #expect(!out.allItems.contains { if case .caption(let c) = $0.content { c.words.contains { $0.text == "EDITED" } } else { false } })
        #expect(out.tracks.first { $0.kind == .music }?.muted == true)
        #expect(errors(out).isEmpty, "\(errors(out))")
        // The locked page isn't doubled by the new draft's page at the same time.
        let captionItems = out.tracks.filter { $0.kind == .caption }.flatMap(\.items)
        #expect(captionItems.filter { $0.range.overlaps(pages[0].range) }.count == 1)
    }

    @Test func sameInputsWithNothingKeptReproduceTheDraft() {
        let tl = DraftPipeline.run(talkingInput()).timeline
        let result = Redraft.merge(tl, into: DraftPipeline.run(talkingInput()).timeline)
        #expect(result.kept == 0)
        #expect(result.timeline == tl)
    }

    @Test func lockedTracksAreKeptWhole() throws {
        var tl = DraftPipeline.run(talkingInput()).timeline
        let ci = try #require(tl.tracks.firstIndex { $0.kind == .caption })
        let before = tl.tracks[ci].items
        tl.tracks[ci].locked = true
        var other = talkingInput()
        other.template.rules.captions?.style = "clean-subtitle"
        let out = Redraft.merge(tl, into: DraftPipeline.run(other).timeline).timeline
        let captions = out.tracks.first { $0.kind == .caption }
        #expect(captions?.locked == true)
        #expect(captions?.items.map(\.id) == before.map(\.id))
        #expect(errors(out).isEmpty)
    }
}
