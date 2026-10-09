import ClipperCore
import Foundation
import Testing
@testable import ClipperAutomation

// MARK: - Synthetic inputs

func videoAsset(_ name: String, seconds: Double, width: Int = 1920, height: Int = 1080, audio: Bool = true) -> MediaAsset {
    var g = IDGenerator(seed: stableHash(name))
    return MediaAsset(id: g.uuid(), key: AssetKey(name), name: name, url: URL(fileURLWithPath: "/tmp/\(name).mov"),
                      info: MediaInfo(kind: .video, duration: RationalTime(seconds: seconds), naturalWidth: width, naturalHeight: height,
                                      frameRate: 30, audioChannels: audio ? 2 : 0, audioSampleRate: audio ? 48_000 : 0))
}

/// Words of `sentences`, 0.3 s each with 0.05 s gaps; `pauses[i]` seconds of silence after sentence i.
func transcript(_ sentences: [String], start: Double = 0.5, pauses: [Double]) -> Transcript {
    var t = start
    var words: [TranscriptWord] = []
    for (i, s) in sentences.enumerated() {
        for w in s.split(separator: " ") {
            let filler = ["um", "uh", "um,", "uh,"].contains(w.lowercased())
            words.append(TranscriptWord(text: String(w), start: t, end: t + 0.3, isFiller: filler))
            t += 0.35
        }
        t += i < pauses.count ? pauses[i] : 0.5
    }
    return Transcript(locale: "en-US", engine: "test", words: words)
}

func music(_ id: String, bpm: Double, seconds: Double, moods: [String]) -> MusicTrack {
    let period = 60 / bpm
    let beats = stride(from: 0.25, to: seconds, by: period).map { $0 }
    let downbeats = stride(from: 0, to: beats.count, by: 4).map { beats[$0] }
    return MusicTrack(id: id, title: id, artist: "Test", url: URL(fileURLWithPath: "/tmp/\(id).mp3"), duration: seconds,
                      license: .ccBy(attribution: "\(id) by Test (CC BY 4.0)"), moods: moods, bpm: bpm, energy: 0.7,
                      beats: BeatGrid(bpm: bpm, beats: beats, downbeats: downbeats))
}

let speech = [
    "Welcome back to the channel today we are testing an automatic editor.",
    "Um so the first thing you need to know is that everything runs locally.",
    "There are no subscriptions and no cloud uploads at all!",
    "If the timing is off by a few frames viewers will notice immediately.",
]

func talkingInput(seed: UInt64 = 7, title: String? = "Local editing in 60s") -> DraftInput {
    let a = videoAsset("speaker", seconds: 30)
    let tr = transcript(speech, pauses: [0.2, 1.6, 0.9, 2.5])
    return DraftInput(template: BuiltIns.talkingHead, clips: [ClipInput(asset: a, analysis: AssetAnalysis(transcript: tr))],
                      music: [music("chill", bpm: 96, seconds: 120, moods: ["chill"]), music("rock", bpm: 160, seconds: 120, moods: ["intense"])],
                      settings: DraftSettings(title: title, seed: seed))
}

// MARK: - Tests

@Suite struct CuttingTests {
    @Test func silenceCutMergesShortPausesAndCutsLongOnesAndFillers() {
        let tr = transcript(["one two", "um", "three four", "five"], start: 1, pauses: [0.2, 0.2, 1.5])
        let ranges = Cutting.keepRanges(words: tr.words, speech: [], clip: 0...20, rule: SilenceCutRule(minGap: 0.4, padBefore: 0.08, padAfter: 0.12))
        // "one two" | (um removed) | "three four" | (1.5 s pause) | "five"
        #expect(ranges.count == 3)
        let um = tr.words.first { $0.isFiller }!
        #expect(!ranges.contains { $0.contains((um.start + um.end) / 2) })
        #expect(abs(ranges[0].lowerBound - 0.92) < 1e-9)   // padded 80 ms before the first word
    }

    @Test func clipWithoutSpeechIsKeptWhole() {
        #expect(Cutting.keepRanges(words: [], speech: [], clip: 2...9, rule: SilenceCutRule()) == [2...9])
    }

    @Test func fitDropsLowDensitySegmentsButKeepsTheHook() {
        var report = DraftReport()
        let segs = [Segment(clip: 0, start: 0, end: 10, words: Array(repeating: TranscriptWord(text: "w", start: 1, end: 1.2), count: 20)),
                    Segment(clip: 0, start: 12, end: 22, words: []),
                    Segment(clip: 0, start: 24, end: 34, words: Array(repeating: TranscriptWord(text: "w", start: 25, end: 25.2), count: 25))]
        let out = Cutting.fit(segs, maxDuration: 21, report: &report)
        #expect(out.map(\.start) == [0, 24])
        #expect(out.reduce(0) { $0 + $1.duration } <= 21)
    }
}

@Suite struct DraftTests {
    func json(_ t: Timeline) throws -> String { String(decoding: try ClipperJSON.encode(t), as: UTF8.self) }

    @Test func talkingHeadDraftIsCompleteAndValid() throws {
        let input = talkingInput()
        let r = DraftPipeline.run(input)
        let tl = r.timeline
        let durations = Dictionary(uniqueKeysWithValues: (input.clips.map(\.asset) + r.addedAssets).map { ($0.id, $0.info.duration) })
        #expect(tl.validate(assetDurations: durations).filter { $0.severity == .error }.isEmpty)
        #expect(r.report.warnings.isEmpty, "\(r.report.warnings)")

        let video = tl.tracks.first { $0.kind == .video }!
        #expect(video.items.count >= 3)                                 // long pauses + the filler were cut
        #expect(r.report.removedSeconds > 3)
        #expect(video.items.allSatisfy { $0.start == $0.start.roundedToFrame(.fps30) })   // frame-accurate
        #expect(zip(video.items, video.items.dropFirst()).allSatisfy { $0.end == $1.start })   // no gaps

        let captions = tl.tracks.first { $0.kind == .caption }!
        #expect(!captions.items.isEmpty)
        for c in captions.items { if case .caption(let cap) = c.content { #expect(cap.words.count <= 3) } }
        #expect(!captions.items.contains { if case .caption(let c) = $0.content { c.words.contains { $0.text.uppercased() == "UM" } } else { false } })

        let musicTrack = tl.tracks.first { $0.kind == .music }!
        #expect(r.report.musicTrack == "chill")                          // mood match beats the 160 BPM rock track
        #expect(musicTrack.items.first?.gain.isAnimated == true)         // ducked under speech
        #expect(tl.attributions == ["chill by Test (CC BY 4.0)"])
        #expect(tl.tracks.contains { $0.kind == .title })
        #expect(abs(musicTrack.end.seconds - tl.duration.seconds) < 0.05)
        #expect(tl.tracks.last?.kind == .music && tl.tracks.firstIndex { $0.kind == .caption }! > tl.tracks.firstIndex { $0.kind == .video }!)
    }

    @Test func draftsAreDeterministic() throws {
        let a = try json(DraftPipeline.run(talkingInput(seed: 7)).timeline)
        let b = try json(DraftPipeline.run(talkingInput(seed: 7)).timeline)
        #expect(a == b)
        let c = try json(DraftPipeline.run(talkingInput(seed: 8)).timeline)
        #expect(a != c)
    }

    @Test func titleElementSkippedWithoutTitle() {
        let tl = DraftPipeline.run(talkingInput(title: nil)).timeline
        #expect(!tl.tracks.contains { $0.kind == .title })
    }

    @Test func maxDurationIsRespected() {
        var input = talkingInput()
        input.settings.maxDuration = 6
        let tl = DraftPipeline.run(input).timeline
        #expect(tl.tracks.first { $0.kind == .video }!.end.seconds <= 6.01)
    }

    @Test func montageCutsLandOnBeats() {
        let clips = (0..<5).map { ClipInput(asset: videoAsset("clip\($0)", seconds: 8, audio: false)) }
        let m = music("beat120", bpm: 120, seconds: 60, moods: ["upbeat"])
        let r = DraftPipeline.run(DraftInput(template: BuiltIns.montage, clips: clips, music: [m], settings: DraftSettings(title: "Trip", seed: 1)))
        let items = r.timeline.tracks.first { $0.kind == .video }!.items
        #expect(items.count >= 10)
        #expect(r.timeline.duration.seconds <= 30.01)
        // 120 BPM, every 4 beats = 2 s; music starts on its first downbeat so cuts are on whole 2 s marks.
        for item in items { #expect(abs(item.start.seconds.truncatingRemainder(dividingBy: 2)) < 0.034) }
        // Clips cycle and advance through their sources on reuse.
        let firstClipUses = items.filter { $0.name == "clip0" }.compactMap { $0.content.mediaRef?.source.start.seconds }
        #expect(firstClipUses.count >= 2 && firstClipUses[1] > firstClipUses[0])
        #expect(r.timeline.tracks.first { $0.kind == .music }!.items.first?.content.mediaRef?.source.start.seconds == 0.25)
    }

    @Test func gameplayAloneGoesFullFrameAndFacecamIsLinked() {
        let game = videoAsset("game", seconds: 40)
        let tr = transcript(speech, pauses: [0.3, 2, 0.4, 3])
        let alone = DraftPipeline.run(DraftInput(template: BuiltIns.gameplay, clips: [ClipInput(asset: game, analysis: AssetAnalysis(transcript: tr))]))
        #expect(alone.timeline.tracks.first { $0.kind == .video }!.items.first?.transform == .fullFrame)

        let cam = videoAsset("cam", seconds: 40, width: 1280, height: 720, audio: false)
        let both = DraftPipeline.run(DraftInput(template: BuiltIns.gameplay, clips: [
            ClipInput(asset: game, analysis: AssetAnalysis(transcript: tr)), ClipInput(asset: cam, slot: "facecam")]))
        let tracks = both.timeline.tracks.filter { $0.kind == .video }
        #expect(tracks.count == 2)
        let gameItems = tracks.first { $0.name == "Gameplay" }!.items, camItems = tracks.first { $0.name == "Facecam" }!.items
        #expect(gameItems.count == camItems.count)
        for (g, c) in zip(gameItems, camItems) {
            #expect(g.range == c.range)
            #expect(g.content.mediaRef?.source == c.content.mediaRef?.source)   // cut in sync
        }
        #expect(gameItems[0].transform.box == NormSize(1, 0.6))
    }

    @Test func vlogTrimsSilentBroll() {
        let broll = (0..<3).map { ClipInput(asset: videoAsset("broll\($0)", seconds: 12, audio: false)) }
        let r = DraftPipeline.run(DraftInput(template: BuiltIns.vlog, clips: broll))
        let items = r.timeline.tracks.first { $0.kind == .video }!.items
        #expect(items.count == 3)
        #expect(items.allSatisfy { abs($0.range.duration.seconds - 4) < 0.04 })
        #expect(items.allSatisfy { abs(($0.content.mediaRef?.source.start.seconds ?? 0) - 4) < 0.04 })   // middle of the clip
        #expect(r.report.warnings.contains { $0.contains("music") })     // no music offered
    }

    @Test func reframeFollowsTheFace() {
        let a = videoAsset("wide", seconds: 10)
        let faces = FaceTrack(samples: stride(from: 0.0, to: 10, by: 0.25).map {
            FaceSample(time: $0, rect: NormRect(x: 0.1 + $0 * 0.05, y: 0.3, width: 0.1, height: 0.2), confidence: 0.9)
        })
        let tr = transcript(["just talking while walking across the frame slowly"], pauses: [])
        let r = DraftPipeline.run(DraftInput(template: BuiltIns.talkingHead, clips: [ClipInput(asset: a, analysis: AssetAnalysis(transcript: tr, faces: faces))]))
        let item = r.timeline.tracks.first { $0.kind == .video }!.items[0]
        #expect(item.transform.focus.isAnimated)
        let early = item.transform.focus.value(at: RationalTime(seconds: 0.5)).x
        let late = item.transform.focus.value(at: item.range.duration).x
        #expect(late > early + 0.1)
    }

    @Test func builtInTemplatesRoundTripAsJSON() throws {
        for t in BuiltIns.templates {
            let data = try ClipperJSON.encode(t)
            #expect(try ClipperJSON.decode(Template.self, from: data) == t)
        }
        let used = Set(BuiltIns.templates.compactMap { $0.rules.captions?.style })
        let known = Set(BuiltIns.styles.keys).union(["gameplay-caption"])
        #expect(used.isSubset(of: known))
    }

    @Test func captionsDisplayRules() {
        let s = BuiltIns.styles["bold-pop"]!
        #expect(Captions.display("editor.", style: s) == "editor")
        #expect(Captions.display("really?", style: s) == "really?")
        #expect(Captions.isEmphasis("60") && Captions.isEmphasis("wow!") && !Captions.isEmphasis("hello"))
    }
}
