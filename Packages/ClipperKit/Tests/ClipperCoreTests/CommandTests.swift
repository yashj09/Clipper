import Foundation
import Testing
@testable import ClipperCore

/// Builds a 2-track timeline: video track with clips [0,4) [4,10), title track empty.
func makeTimeline() -> (Timeline, asset: AssetID, a: ItemID, b: ItemID, video: TrackID, titles: TrackID) {
    let asset = UUID()
    let a = Item(name: "A", range: TimeRange(seconds: 0, 4),
                 content: .media(MediaRef(asset: asset, source: TimeRange(seconds: 10, 14))),
                 opacity: .keyframes([Keyframe(RationalTime(seconds: 1), 0), Keyframe(RationalTime(seconds: 2), 1)]))
    let b = Item(name: "B", range: TimeRange(seconds: 4, 10), content: .media(MediaRef(asset: asset, source: TimeRange(seconds: 20, 26))))
    let video = Track(kind: .video, items: [a, b])
    let titles = Track(kind: .title)
    let tl = Timeline(name: "T", canvas: .vertical1080, tracks: [video, titles])
    return (tl, asset, a.id, b.id, video.id, titles.id)
}

func ctx(_ asset: AssetID) -> EditContext { EditContext(assetDurations: [asset: RationalTime(seconds: 60)]) }

@Suite struct CommandTests {
    @Test func insertRejectsOverlapButOverwriteSplits() throws {
        let (tl, asset, _, b, video, _) = makeTimeline()
        let x = Item(name: "X", range: TimeRange(seconds: 6, 7), content: .solid(.black))
        #expect(throws: EditError.overlap(video)) { try InsertItem(x, on: video).apply(to: tl, context: ctx(asset)) }

        let out = try InsertItem(x, on: video, mode: .overwrite).apply(to: tl, context: ctx(asset))
        let items = out.tracks[0].items
        #expect(items.map(\.name) == ["A", "B", "X", "B"])
        #expect(items[1].range == TimeRange(seconds: 4, 6))
        #expect(items[3].range == TimeRange(seconds: 7, 10))
        #expect(items[3].content.mediaRef?.source == TimeRange(seconds: 23, 26))   // tail stays in sync with media
        #expect(items[3].id != b)
        #expect(out.validate(assetDurations: [asset: RationalTime(seconds: 60)]).isEmpty)
    }

    @Test func bladeSplitsAndKeepsMediaInSync() throws {
        let (tl, asset, a, _, _, _) = makeTimeline()
        let out = try Blade(at: RationalTime(seconds: 1.5)).apply(to: tl, context: ctx(asset))
        let items = out.tracks[0].items
        #expect(items.count == 3)
        #expect(items[0].id == a && items[0].range == TimeRange(seconds: 0, 1.5))
        #expect(items[1].content.mediaRef?.source == TimeRange(seconds: 11.5, 14))
        // Keyframes on the tail are re-based: opacity reached 0.5 at t=1.5 on the original.
        #expect(abs(items[1].opacity.value(at: .zero) - items[0].opacity.value(at: RationalTime(seconds: 1.5))) < 1e-9)
        #expect(out.validate().isEmpty)
    }

    @Test func trimStartShiftsSourceAndKeyframes() throws {
        let (tl, asset, a, _, _, _) = makeTimeline()
        let out = try TrimItem(a, edge: .start, to: RationalTime(seconds: 1)).apply(to: tl, context: ctx(asset))
        let item = out.item(a)!
        #expect(item.range == TimeRange(seconds: 1, 4))
        #expect(item.content.mediaRef?.source == TimeRange(seconds: 11, 14))
        #expect(item.opacity.keys.first?.time == .zero)   // keyframe at 1s now at item start
    }

    @Test func trimCannotPassMediaBounds() {
        let (tl, asset, a, _, _, _) = makeTimeline()
        // A starts at source 10s; extending its head by 11 s would need source -1s.
        #expect(throws: EditError.self) {
            try TrimItem(a, edge: .start, to: RationalTime(seconds: -11)).apply(to: tl, context: ctx(asset))
        }
    }

    @Test func rippleTrimEndMovesFollowers() throws {
        let (tl, asset, a, b, _, _) = makeTimeline()
        let out = try TrimItem(a, edge: .end, to: RationalTime(seconds: 3), ripple: true).apply(to: tl, context: ctx(asset))
        #expect(out.item(b)!.range == TimeRange(seconds: 3, 9))
        #expect(out.validate().isEmpty)
    }

    @Test func rippleTrimStartKeepsPositionAndPullsFollowers() throws {
        let (tl, asset, a, b, _, _) = makeTimeline()
        let out = try TrimItem(a, edge: .start, to: RationalTime(seconds: 1), ripple: true).apply(to: tl, context: ctx(asset))
        #expect(out.item(a)!.range == TimeRange(seconds: 0, 3))
        #expect(out.item(a)!.content.mediaRef?.source == TimeRange(seconds: 11, 14))
        #expect(out.item(b)!.range == TimeRange(seconds: 3, 9))
    }

    @Test func rippleDeleteClosesGap() throws {
        let (tl, asset, a, b, _, _) = makeTimeline()
        let out = try DeleteItems([a], ripple: true).apply(to: tl, context: ctx(asset))
        #expect(out.item(b)!.range == TimeRange(seconds: 0, 6))
    }

    @Test func moveAcrossTracks() throws {
        let (tl, asset, a, _, _, titles) = makeTimeline()
        let out = try MoveItem(a, to: titles, at: RationalTime(seconds: 2)).apply(to: tl, context: ctx(asset))
        #expect(out.tracks[0].items.count == 1)
        #expect(out.tracks[1].items.first?.range == TimeRange(seconds: 2, 6))
    }

    @Test func lockedTrackRejectsEdits() {
        var (tl, asset, a, _, _, _) = makeTimeline()
        tl.tracks[0].locked = true
        #expect(throws: EditError.self) { try DeleteItems([a]).apply(to: tl, context: ctx(asset)) }
    }

    @Test func undoRedoAndCoalescing() throws {
        var (tl, asset, a, _, _, _) = makeTimeline()
        let original = tl
        var history = EditHistory()
        // Three slider ticks coalesce into one undo step.
        for v in [0.2, 0.4, 0.6] {
            try history.perform(ModifyItem(a, name: "Opacity", coalescingKey: "opacity") { $0.opacity = .constant(v) },
                                on: &tl, context: ctx(asset))
        }
        #expect(history.undoStack.count == 1)
        history.breakCoalescing()
        try history.perform(Blade(at: RationalTime(seconds: 2)), on: &tl, context: ctx(asset))
        #expect(history.undoStack.count == 2)

        history.undo(&tl); history.undo(&tl)
        #expect(tl == original)
        history.redo(&tl)
        #expect(tl.item(a)?.opacity == .constant(0.6))
    }
}

/// Property test: random edit sequences never break timeline invariants.
@Suite struct CommandPropertyTests {
    @Test(arguments: 0..<20)
    func randomEditsPreserveInvariants(seed: Int) throws {
        var rng = IDGenerator(seed: UInt64(seed))
        var (tl, asset, _, _, _, _) = makeTimeline()
        let context = EditContext(assetDurations: [asset: RationalTime(seconds: 60)])
        var history = EditHistory()
        func randTime(_ maxS: Double) -> RationalTime { RationalTime(seconds: rng.unit() * maxS).roundedToFrame(.fps30) }

        for _ in 0..<150 {
            let items = tl.allItems
            let pick = items.isEmpty ? nil : items[Int(rng.next() % UInt64(items.count))]
            let track = tl.tracks[Int(rng.next() % UInt64(tl.tracks.count))].id
            let cmd: any EditCommand
            switch rng.next() % 7 {
            case 0:
                let s = randTime(20)
                let src = randTime(50)
                cmd = InsertItem(Item(name: "N", range: TimeRange(start: s, duration: RationalTime(seconds: 1 + rng.unit() * 3).roundedToFrame(.fps30)),
                                      content: .media(MediaRef(asset: asset, source: TimeRange(start: src, duration: .zero)))),
                                 on: track, mode: rng.next() % 2 == 0 ? .overwrite : .reject)
            case 1: cmd = Blade(at: randTime(20))
            case 2: guard let p = pick else { continue }; cmd = TrimItem(p.id, edge: .start, to: p.start + randTime(2) - RationalTime(seconds: 1), ripple: rng.next() % 2 == 0)
            case 3: guard let p = pick else { continue }; cmd = TrimItem(p.id, edge: .end, to: p.end + randTime(2) - RationalTime(seconds: 1), ripple: rng.next() % 2 == 0)
            case 4: guard let p = pick else { continue }; cmd = MoveItem(p.id, to: track, at: randTime(20), mode: rng.next() % 2 == 0 ? .overwrite : .reject)
            case 5: guard let p = pick else { continue }; cmd = DeleteItems([p.id], ripple: rng.next() % 2 == 0)
            default:
                if rng.next() % 2 == 0 { history.undo(&tl) } else { history.redo(&tl) }
                #expect(tl.validate(assetDurations: context.assetDurations).filter { $0.severity == .error }.isEmpty)
                continue
            }
            // Fix up the random insert so its source duration matches its timeline duration.
            var command = cmd
            if var ins = cmd as? InsertItem, case .media(var m) = ins.item.content {
                m.source.duration = ins.item.range.duration
                if m.source.end > RationalTime(seconds: 60) { continue }
                ins.item.content = .media(m)
                command = ins
            }
            do { try history.perform(command, on: &tl, context: context) } catch is EditError { continue }
            let errors = tl.validate(assetDurations: context.assetDurations).filter { $0.severity == .error }
            #expect(errors.isEmpty, "after \(command.name): \(errors)")
            if !errors.isEmpty { return }
        }
    }
}

@Suite struct DocumentTests {
    @Test func projectRoundTripsByteForByte() throws {
        let (tl, _, _, _, _, _) = makeTimeline()
        var timeline = tl
        timeline.styles["caption"] = TextStyle(highlight: .init(color: RGBA(1, 0.85, 0.1)), animation: .pop)
        timeline.tracks[1].items.append(Item(name: "Cap", range: TimeRange(seconds: 0, 2),
            content: .caption(CaptionContent(words: [.init(text: "hi", start: .zero, end: RationalTime(seconds: 0.5))], style: "caption")),
            origin: .auto(pass: "captions")))
        let project = Project(name: "P", timelines: [timeline], created: Date(timeIntervalSince1970: 1_700_000_000))
        let data = try ClipperJSON.encode(project)
        let decoded = try ClipperJSON.decodeProject(data)
        #expect(decoded.created == project.created)
        #expect(decoded.timelines[0].tracks == project.timelines[0].tracks)
        #expect(decoded.timelines[0].styles == project.timelines[0].styles)
        #expect(decoded.timelines[0].canvas == project.timelines[0].canvas)
        #expect(decoded == project)
        #expect(try ClipperJSON.encode(decoded) == data)
        let s = String(decoding: data, as: UTF8.self)
        #expect(s.contains("\"auto:captions\""))
        #expect(s.contains("\"type\" : \"caption\""))
    }

    @Test func rejectsNewerSchema() {
        let json = Data(#"{"schemaVersion": 99}"#.utf8)
        #expect(throws: ProjectError.self) { try ClipperJSON.decodeProject(json) }
    }
}

@Suite struct SettingsTests {
    @Test func oldSettingsFilesKeepLoading() throws {
        let old = Data(#"{"automation": {"defaultTemplate": "vlog", "captions": false}, "export": {"defaultPreset": "youtube-1080p"}}"#.utf8)
        let s = try ClipperJSON.decode(ClipperSettings.self, from: old)
        #expect(s.automation.defaultTemplate == "vlog" && !s.automation.captions)
        #expect(s.automation.useLLM == false && s.automation.llmModel == "qwen3:14b" && s.automation.autoBRoll)   // new keys default
        #expect(s.export.defaultPreset == "youtube-1080p")
        #expect(try ClipperJSON.decode(ClipperSettings.self, from: ClipperJSON.encode(s)) == s)
    }
}

@Suite struct BeatOctaveTests {
    @Test func halvesADoubleTempoGrid() {
        let beats = stride(from: 0.1, to: 20, by: 60.0 / 192).map { $0 }
        let g = BeatGrid(bpm: 192, beats: beats, downbeats: stride(from: 0, to: beats.count, by: 4).map { beats[$0] })
        let fixed = g.resolvingOctave(toward: 96)
        #expect(fixed.bpm == 96)
        #expect(abs((fixed.beats[1] - fixed.beats[0]) - 0.625) < 1e-9)
        #expect(fixed.beats.first == g.downbeats.first)
        #expect(g.resolvingOctave(toward: 190) == g)   // no octave error → unchanged
    }

    @Test func doublesAHalfTempoGrid() {
        let beats = stride(from: 0, to: 10, by: 1.0).map { $0 }
        let fixed = BeatGrid(bpm: 60, beats: beats).resolvingOctave(toward: 120)
        #expect(fixed.bpm == 120 && fixed.beats.count == beats.count * 2 - 1)
    }
}
