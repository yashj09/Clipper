import ClipperCore
import Foundation
import Testing
@testable import ClipperPublish

// MARK: - Fixture

/// 1080×1920 @ 30 fps:
/// - Main (video): interview [0,3) ← src 10–13 s · gap [3,4) · broll [4,7) ← src 0–3 s · interview [7,9) @2× ← src 20–24 s
/// - PiP (overlay): facecam [1,5), 0.4×0.225 box centred at (0.75, 0.2), opacity 0.9, 0.5 s fade-in
/// - Titles: "Hello" [0,2) at (0.5, 0.25)
/// - Captions (en): "hi there" [0.5,1.5), "general kenobi" [1.5,2.5)
/// - Music: song [0,9), ducked 0 → −12 dB at 2.0–2.2 s and back at 6.0–6.4 s, 1 s fade-out, track gain −2 dB
enum Fixture {
    static let interview = AssetID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    static let broll = AssetID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    static let facecam = AssetID(uuidString: "00000000-0000-0000-0000-00000000000C")!
    static let song = AssetID(uuidString: "00000000-0000-0000-0000-00000000000D")!

    static func s(_ x: Double) -> RationalTime { RationalTime(seconds: x) }
    static func r(_ a: Double, _ b: Double) -> TimeRange { TimeRange(seconds: a, b) }

    static var assets: [AssetID: MediaAsset] {
        func video(_ id: AssetID, _ name: String, _ path: String, _ w: Int, _ h: Int, _ dur: Double, channels: Int) -> MediaAsset {
            MediaAsset(id: id, key: AssetKey(name), name: name, url: URL(fileURLWithPath: path),
                       info: MediaInfo(kind: .video, duration: s(dur), naturalWidth: w, naturalHeight: h, frameRate: 30,
                                       videoCodec: "hvc1", audioChannels: channels, audioSampleRate: 48_000))
        }
        return [
            interview: video(interview, "interview", "/Volumes/Media/My Clips/interview.mov", 1920, 1080, 60, channels: 2),
            broll: video(broll, "broll", "/Volumes/Media/broll.mov", 1080, 1920, 20, channels: 2),
            facecam: video(facecam, "facecam", "/Volumes/Media/facecam.mp4", 1280, 720, 30, channels: 1),
            song: MediaAsset(id: song, key: AssetKey("song"), name: "song", url: URL(fileURLWithPath: "/Music/song.m4a"),
                             info: MediaInfo(kind: .audio, duration: s(120), audioChannels: 2, audioSampleRate: 44_100)),
        ]
    }

    static var timeline: Timeline {
        let main = Track(kind: .video, name: "Main", items: [
            Item(name: "A1", range: r(0, 3), content: .media(MediaRef(asset: interview, source: r(10, 13)))),
            Item(name: "B1", range: r(4, 7), content: .media(MediaRef(asset: broll, source: r(0, 3)))),
            Item(name: "A2 fast", range: r(7, 9), content: .media(MediaRef(asset: interview, source: r(20, 24), speed: 2))),
        ])
        let pip = Track(kind: .overlay, name: "PiP", items: [
            Item(name: "Facecam", range: r(1, 5), content: .media(MediaRef(asset: facecam, source: r(0, 4))),
                 transform: Transform(box: NormSize(0.4, 0.225), position: .constant(NormPoint(0.75, 0.2)), fit: .fill),
                 opacity: .constant(0.9), fadeIn: s(0.5)),
        ])
        let titles = Track(kind: .title, name: "Titles", items: [
            Item(range: r(0, 2), content: .text(TextContent(text: "Hello", style: "title")),
                 transform: Transform(position: .constant(NormPoint(0.5, 0.25)))),
        ])
        func page(_ a: Double, _ b: Double, _ words: [String]) -> Item {
            let step = (b - a) / Double(words.count)
            return Item(range: r(a, b), content: .caption(CaptionContent(words: words.enumerated().map { i, w in
                .init(text: w, start: s(Double(i) * step), end: s(Double(i + 1) * step))
            }, style: "caption")))
        }
        let captions = Track(kind: .caption, name: "Captions", items: [
            page(0.5, 1.5, ["hi", "there"]), page(1.5, 2.5, ["general", "kenobi"]),
        ], language: "en")
        let duck: [Keyframe<Double>] = [
            Keyframe(s(0), 0, .linear), Keyframe(s(2), 0, .linear), Keyframe(s(2.2), -12, .linear),
            Keyframe(s(6), -12, .linear), Keyframe(s(6.4), 0, .linear),
        ]
        let music = Track(kind: .music, name: "Music", items: [
            Item(name: "Song", range: r(0, 9), content: .media(MediaRef(asset: song, source: r(0, 9))),
                 gain: .keyframes(duck), fadeOut: s(1)),
        ], gain: -2)
        return Timeline(name: "Fixture Short", canvas: .vertical1080, tracks: [main, pip, titles, captions, music],
                        styles: ["title": TextStyle(font: "HelveticaNeue-Bold", size: 0.05, position: NormPoint(0.5, 0.25)),
                                 "caption": TextStyle(box: .init(color: RGBA(0, 0, 0, 0.5)))])
    }

    /// The fixture with markers on A1, the gap and the 2× clip.
    static var markedTimeline: Timeline {
        var t = timeline
        t.markers = [Marker(time: s(1.5), name: "Chapter: Intro"), Marker(time: s(3.5), name: "Chapter: Gap"),
                     Marker(time: s(8), name: "Retake")]
        return t
    }

    /// 1920×1080 @ 29.97: clips on frames [0,45) and [46,100).
    static var ntscTimeline: Timeline {
        let rate = FrameRate.ntsc30
        let frames = { (n: Int64) in rate.time(ofFrame: n) }
        var timeline = Timeline(name: "ntsc", canvas: Canvas(width: 1920, height: 1080, frameRate: rate))
        timeline.tracks = [Track(kind: .video, items: [
            Item(range: TimeRange(start: frames(0), end: frames(45)),
                 content: .media(MediaRef(asset: interview, source: TimeRange(start: .zero, duration: frames(45))))),
            Item(range: TimeRange(start: frames(46), end: frames(100)),
                 content: .media(MediaRef(asset: broll, source: TimeRange(start: .zero, duration: frames(54))))),
        ])]
        return timeline
    }
}

// MARK: - Helpers

/// FCPXML time string → exact (numerator, denominator).
func fcpTime(_ s: String?) -> (Int64, Int64)? {
    guard var s, s.hasSuffix("s") else { return nil }
    s.removeLast()
    let parts = s.split(separator: "/")
    guard let n = Int64(parts[0]) else { return nil }
    return parts.count == 2 ? Int64(parts[1]).map { (n, $0) } : (n, 1)
}

func same(_ a: (Int64, Int64)?, _ b: (Int64, Int64)?) -> Bool {
    guard let a, let b else { return false }
    return a.0 * b.1 == b.0 * a.1
}

func add(_ a: (Int64, Int64), _ b: (Int64, Int64)) -> (Int64, Int64) { (a.0 * b.1 + b.0 * a.1, a.1 * b.1) }

extension XMLNode {
    func nodes(_ xpath: String) -> [XMLElement] { ((try? nodes(forXPath: xpath)) ?? []).compactMap { $0 as? XMLElement } }
    func first(_ xpath: String) -> XMLElement? { nodes(xpath).first }
}

extension XMLElement {
    subscript(_ name: String) -> String? { attribute(forName: name)?.stringValue }
}

func fcpxmlDocument(_ timeline: Timeline = Fixture.timeline, _ exporter: FCPXMLExporter = FCPXMLExporter()) throws -> (Data, XMLDocument) {
    let data = try exporter.export(timeline, assets: Fixture.assets)
    return (data, try XMLDocument(data: data))
}

func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: executable)
    p.arguments = arguments
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

func temporaryFile(_ data: Data, ext: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("clipper-interchange-\(UUID().uuidString).\(ext)")
    try data.write(to: url)
    return url
}

let uvx: String? = ["/opt/homebrew/bin/uvx", "/usr/local/bin/uvx", NSHomeDirectory() + "/.local/bin/uvx"]
    .first { FileManager.default.isExecutableFile(atPath: $0) }

// MARK: - FCPXML

@Suite struct InterchangeTests {
    @Test func fcpxmlHeaderAndResources() throws {
        let (data, doc) = try fcpxmlDocument()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\""))
        #expect(text.contains("<!DOCTYPE fcpxml>"))
        let root = try #require(doc.rootElement())
        #expect(root.name == "fcpxml")
        #expect(root["version"] == "1.11")

        let seqFormat = try #require(doc.first("/fcpxml/resources/format[@id='r1']"))
        #expect(seqFormat["frameDuration"] == "1/30s")
        #expect(seqFormat["width"] == "1080" && seqFormat["height"] == "1920")
        #expect(seqFormat["colorSpace"] == "1-1-1 (Rec. 709)")
        #expect(seqFormat["name"] == nil)   // custom vertical size

        let assets = doc.nodes("/fcpxml/resources/asset")
        #expect(assets.count == 4)
        let interview = try #require(assets.first { $0["name"] == "interview" })
        #expect(interview["duration"] == "60s")
        #expect(interview["hasVideo"] == "1" && interview["hasAudio"] == "1")
        #expect(interview["audioChannels"] == "2" && interview["audioRate"] == "48000")
        #expect(interview.first("media-rep")?["kind"] == "original-media")
        #expect(interview.first("media-rep")?["src"] == "file:///Volumes/Media/My%20Clips/interview.mov")
        let iFormat = try #require(doc.first("/fcpxml/resources/format[@id='\(interview["format"]!)']"))
        #expect(iFormat["name"] == "FFVideoFormat1080p30")
        #expect(iFormat["width"] == "1920" && iFormat["height"] == "1080")
        let song = try #require(assets.first { $0["name"] == "song" })
        #expect(song["hasVideo"] == nil && song["format"] == nil)
        #expect(song["audioRate"] == "44100" && song["duration"] == "120s")

        let effect = try #require(doc.first("/fcpxml/resources/effect"))
        #expect(effect["name"] == "Basic Title")
        #expect(effect["uid"] == FCPXMLExporter.basicTitleUID)
        #expect(doc.first("/fcpxml/library/event/project")?["name"] == "Fixture Short")
        let sequence = try #require(doc.first("//sequence"))
        #expect(sequence["format"] == "r1" && sequence["duration"] == "9s")
    }

    @Test func fcpxmlSpineIsContiguousWithExactTimes() throws {
        let (_, doc) = try fcpxmlDocument()
        let spine = try #require(doc.first("//sequence/spine"))
        let children = (spine.children ?? []).compactMap { $0 as? XMLElement }
        #expect(children.map(\.name!) == ["asset-clip", "gap", "asset-clip", "asset-clip"])
        #expect(children.map { $0["offset"]! } == ["0s", "3s", "4s", "7s"])
        #expect(children.map { $0["duration"]! } == ["3s", "1s", "3s", "2s"])

        var cursor: (Int64, Int64) = (0, 1)
        for c in children {
            #expect(same(fcpTime(c["offset"]), cursor), "spine gap/overlap at \(c["name"] ?? "")")
            cursor = add(cursor, try #require(fcpTime(c["duration"])))
        }
        #expect(same(cursor, fcpTime(doc.first("//sequence")?["duration"])))

        // Source in-points on the asset's frame grid.
        #expect(children[0]["start"] == "10s" && children[0]["name"] == "A1")
        #expect(children[2]["start"] == "0s")
        // Primary clips keep audio, so no srcEnable.
        #expect(children[0]["srcEnable"] == nil)
    }

    @Test func fcpxmlSpeedChangeUsesTimeMap() throws {
        let (_, doc) = try fcpxmlDocument()
        let fast = try #require(doc.first("//spine/asset-clip[@name='A2 fast']"))
        // 2× speed: local (retimed) start = 20 s / 2.
        #expect(fast["start"] == "10s" && fast["duration"] == "2s")
        let points = fast.nodes("timeMap/timept")
        #expect(points.map { $0["time"]! } == ["0s", "10s", "12s"])
        #expect(points.map { $0["value"]! } == ["0s", "20s", "24s"])
        #expect(points.allSatisfy { $0["interp"] == "linear" })
        // timeMap precedes the intrinsic adjustments (DTD order).
        #expect((fast.children?.first as? XMLElement)?.name == "timeMap")
    }

    @Test func fcpxmlConnectedClipsAndLanes() throws {
        let (_, doc) = try fcpxmlDocument()
        let a1 = try #require(doc.first("//spine/asset-clip[@name='A1']"))
        let anchored = (a1.children ?? []).compactMap { $0 as? XMLElement }.filter { $0["lane"] != nil }
        // PiP (lane 1), title (2), two captions (3), music (−1): all start inside A1 [0, 3).
        #expect(anchored.count == 5)
        let pip = try #require(anchored.first { $0["name"] == "Facecam" })
        #expect(pip.name == "asset-clip" && pip["lane"] == "1")
        // Anchored offsets are in A1's local time: start 10 s + 1 s.
        #expect(pip["offset"] == "11s" && pip["start"] == "0s" && pip["duration"] == "4s")
        #expect(pip["srcEnable"] == "video")   // overlay tracks don't play audio in Clipper

        let title = try #require(anchored.first { $0.name == "title" })
        #expect(title["lane"] == "2" && title["offset"] == "10s" && title["duration"] == "2s")

        let captions = anchored.filter { $0.name == "caption" }
        #expect(captions.map { $0["lane"]! } == ["3", "3"])
        #expect(captions.map { $0["offset"]! } == ["315/30s", "345/30s"])
        #expect(captions.allSatisfy { $0["role"] == "iTT?captionFormat=ITT.en" })
        #expect(captions.map { $0.first("text/text-style")?.stringValue } == ["hi there", "general kenobi"])
        #expect(captions[0].first("text")?["placement"] == "bottom")

        let music = try #require(anchored.first { $0["name"] == "Song" })
        #expect(music["lane"] == "-1" && music["offset"] == "10s" && music["duration"] == "9s")
        #expect(music["audioRole"] == "music" && music["start"] == "0s")
    }

    @Test func fcpxmlTransformsOpacityAndTrim() throws {
        let (_, doc) = try fcpxmlDocument()
        // 16:9 source filling a 9:16 frame: FCP fits it (×0.5625), so scale 1920/607.5 = 3.160494 to fill.
        let a1 = try #require(doc.first("//spine/asset-clip[@name='A1']"))
        let t1 = try #require(a1.first("adjust-transform"))
        #expect(t1["scale"] == "3.160494 3.160494" && t1["position"] == "0 0" && t1["rotation"] == "0")
        #expect(a1.first("adjust-crop") == nil)   // full-frame: overflow falls outside the frame
        // 9:16 source on 9:16 frame: identity, no adjustment emitted.
        #expect(doc.first("//spine/asset-clip[@name='B1']/adjust-transform") == nil)

        // PiP: 432×432 px box centred at (810, 384) px; 1280×720 source conformed ×0.84375 → 1080×607.5.
        let pip = try #require(doc.first("//asset-clip[@name='Facecam']"))
        let t = try #require(pip.first("adjust-transform"))
        // Position: (810 − 540, 384 − 960) px → (270/1920, 576/1920) × 100, y up.
        #expect(t["position"] == "14.0625 30")
        #expect(t["scale"] == "0.711111 0.711111")
        // Fill crops the 1280-wide source to its centre 720 px: 280 px × 0.84375 / 1920 × 100 per side.
        let trim = try #require(pip.first("adjust-crop[@mode='trim']/trim-rect"))
        #expect(trim["left"] == "12.3047" && trim["right"] == "12.3047" && trim["top"] == "0" && trim["bottom"] == "0")
        let blend = try #require(pip.first("adjust-blend"))
        #expect(blend["amount"] == "0.9")
        #expect(blend.first("param[@name='amount']/fadeIn")?["duration"] == "15/30s")
        // DTD order: crop, transform, blend.
        #expect((pip.children ?? []).compactMap { ($0 as? XMLElement)?.name } == ["adjust-crop", "adjust-transform", "adjust-blend"])

        // Title at y = 0.25 → 25 % of the height above centre.
        let title = try #require(doc.first("//title"))
        #expect(title.first("adjust-transform")?["position"] == "0 25")
        let styleRef = try #require(title.first("text/text-style")?["ref"])
        let style = try #require(title.first("text-style-def[@id='\(styleRef)']/text-style"))
        #expect(title.first("text/text-style")?.stringValue == "Hello")
        #expect(style["font"] == "Helvetica Neue" && style["fontFace"] == "Bold" && style["bold"] == "1")
        #expect(style["fontSize"] == "96")   // 0.05 × 1920
        #expect(style["fontColor"] == "1 1 1 1" && style["alignment"] == "center")
    }

    @Test func fcpxmlVolumeKeyframesForDucking() throws {
        let (_, doc) = try fcpxmlDocument()
        let music = try #require(doc.first("//asset-clip[@name='Song']"))
        let volume = try #require(music.first("adjust-volume"))
        #expect(volume["amount"] == "-2dB")   // item 0 dB + track −2 dB
        let param = try #require(volume.first("param[@name='amount']"))
        #expect(param.first("fadeOut")?["duration"] == "1s")
        #expect(param.first("fadeOut")?["type"] == "linear")
        let keys = param.nodes("keyframeAnimation/keyframe")
        // Keyframe times are in the clip's local time (start 0 s).
        #expect(keys.map { $0["time"]! } == ["0s", "2s", "66/30s", "6s", "192/30s"])
        #expect(keys.map { $0["value"]! } == ["-2dB", "-2dB", "-14dB", "-14dB", "-2dB"])
        // fadeIn/fadeOut precede keyframeAnimation (DTD order).
        #expect((param.children ?? []).compactMap { ($0 as? XMLElement)?.name } == ["fadeOut", "keyframeAnimation"])
    }

    @Test func fcpxmlRefsResolveAndIDsAreUnique() throws {
        let (_, doc) = try fcpxmlDocument()
        let ids = doc.nodes("//*[@id]").map { $0["id"]! }
        #expect(Set(ids).count == ids.count)
        let idSet = Set(ids)
        for el in doc.nodes("//*[@ref]") { #expect(idSet.contains(el["ref"]!), "dangling ref \(el["ref"]!)") }
        for el in doc.nodes("//*[@format]") { #expect(idSet.contains(el["format"]!), "dangling format \(el["format"]!)") }
        // Every anchored element has a non-zero lane; spine children have none.
        for el in doc.nodes("//spine/*/*[@offset]") { #expect(el["lane"] != nil && el["lane"] != "0") }
        for el in doc.nodes("//spine/*") { #expect(el["lane"] == nil) }
        // Every time attribute parses as an exact rational.
        for attr in ["offset", "duration", "start", "time"] {
            for el in doc.nodes("//*[@\(attr)]") { #expect(fcpTime(el[attr]) != nil, "bad time \(el[attr] ?? "")") }
        }
    }

    @Test func fcpxmlNTSCTimesAreFrameExact() throws {
        let (_, doc) = try fcpxmlDocument(Fixture.ntscTimeline)
        #expect(doc.first("//resources/format[@id='r1']")?["frameDuration"] == "1001/30000s")
        #expect(doc.first("//resources/format[@id='r1']")?["name"] == "FFVideoFormat1080p2997")
        let spine = doc.nodes("//spine/*")
        #expect(spine.map { $0["offset"]! } == ["0s", "45045/30000s", "46046/30000s"])
        #expect(spine.map { $0["duration"]! } == ["45045/30000s", "1001/30000s", "54054/30000s"])
        #expect(doc.first("//sequence")?["duration"] == "100100/30000s")
    }

    @Test func fcpxmlCaptionModes() throws {
        let (_, titles) = try fcpxmlDocument(Fixture.timeline, FCPXMLExporter(captionMode: .titles))
        #expect(titles.nodes("//caption").isEmpty)
        #expect(titles.nodes("//title").count == 3)
        let (_, omitted) = try fcpxmlDocument(Fixture.timeline, FCPXMLExporter(version: .v1_10, captionMode: .omit))
        #expect(omitted.nodes("//caption").isEmpty && omitted.nodes("//title").count == 1)
        #expect(omitted.rootElement()?["version"] == "1.10")
        #expect(FCPXMLExporter.captionsSRT(Fixture.timeline).hasPrefix("1\n00:00:00,500 --> 00:00:01,500\nhi there\n"))
    }

    @Test func fcpxmlPrimaryTrackOverrideAndNaming() throws {
        let tl = Fixture.timeline
        let (_, doc) = try fcpxmlDocument(tl, FCPXMLExporter(primaryTrack: tl.tracks[1].id))
        // PiP becomes the storyline: gap [0,1), facecam [1,5), trailing gap to 9 s.
        let spine = doc.nodes("//spine/*")
        #expect(spine.map(\.name!) == ["gap", "asset-clip", "gap"])
        #expect(spine.map { $0["offset"]! } == ["0s", "1s", "5s"])
        // Main sits below the storyline now.
        #expect(doc.first("//asset-clip[@name='A1']")?["lane"] == "-1")
        #expect(doc.first("//asset-clip[@name='Song']")?["lane"] == "-2")

        let named = try FCPXMLExporter().exportFCPXML(tl, assets: Fixture.assets, projectName: "Cut 2")
        #expect(try XMLDocument(data: named).first("//project")?["name"] == "Cut 2")
        #expect(FCPXMLExporter.suggestedFileName(projectName: "My/Short") == "My-Short.fcpxml")
        #expect(OTIOExporter.suggestedFileName(projectName: "Short") == "Short.otio")
    }

    @Test func missingAssetThrows() {
        var assets = Fixture.assets
        assets[Fixture.song] = nil
        let tl = Fixture.timeline
        let expected = InterchangeError.missingAsset(Fixture.song, item: tl.tracks[4].items[0].id)
        #expect(throws: expected) { try FCPXMLExporter().export(tl, assets: assets) }
        #expect(throws: expected) { try OTIOExporter().export(tl, assets: assets) }
    }

    /// `xmllint --noout` on every exporter variant. Optional env:
    /// - `CLIPPER_FCPXML_DTD_DIR`: folder with Apple's `FCPXMLv1_10.dtd` / `FCPXMLv1_11.dtd` (not redistributable, so
    ///   not bundled; e.g. from CommandPost's repo) → also `--dtdvalid` against the matching version.
    /// - `CLIPPER_INTERCHANGE_OUT`: folder to write the documents (and the OTIO) to, for importing into an editor.
    @Test func fcpxmlIsWellFormedPerXmllint() throws {
        let xmllint = "/usr/bin/xmllint"
        guard FileManager.default.isExecutableFile(atPath: xmllint) else { return }
        let env = ProcessInfo.processInfo.environment
        let fixture = Fixture.timeline
        let variants: [(String, Timeline, FCPXMLExporter)] = [
            ("fixture", fixture, FCPXMLExporter()),
            ("fixture-titles-1.10", fixture, FCPXMLExporter(version: .v1_10, captionMode: .titles)),
            ("fixture-pip-primary", fixture, FCPXMLExporter(primaryTrack: fixture.tracks[1].id)),
            ("ntsc", Fixture.ntscTimeline, FCPXMLExporter()),
            ("markers", Fixture.markedTimeline, FCPXMLExporter()),
        ]
        let out = env["CLIPPER_INTERCHANGE_OUT"].map { URL(fileURLWithPath: $0) }
        if let out {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try OTIOExporter().export(fixture, assets: Fixture.assets).write(to: out.appendingPathComponent("fixture.otio"))
        }
        for (name, timeline, exporter) in variants {
            let data = try exporter.export(timeline, assets: Fixture.assets)
            let url = try temporaryFile(data, ext: "fcpxml")
            defer { try? FileManager.default.removeItem(at: url) }
            if let out { try data.write(to: out.appendingPathComponent("\(name).fcpxml")) }
            var args = ["--noout", url.path]
            if let dir = env["CLIPPER_FCPXML_DTD_DIR"] {
                let dtd = URL(fileURLWithPath: dir)
                    .appendingPathComponent("FCPXMLv\(exporter.version.rawValue.replacingOccurrences(of: ".", with: "_")).dtd")
                // As a file URL: xmllint can't open DTD paths containing spaces.
                args.insert(contentsOf: ["--dtdvalid", dtd.absoluteString], at: 0)
            }
            let result = try run(xmllint, args)
            #expect(result.status == 0, "\(name): \(result.output)")
        }
    }

    @Test func fcpxmlMarkersSitOnTheSpineInLocalTime() throws {
        let (_, doc) = try fcpxmlDocument(Fixture.markedTimeline)
        let markers = doc.nodes("//spine/*/marker")
        #expect(markers.map { $0.attribute(forName: "value")?.stringValue } == ["Chapter: Intro", "Chapter: Gap", "Retake"])
        #expect(markers.map { $0.parent?.name } == ["asset-clip", "gap", "asset-clip"])
        // A1 starts at source 10 s; the gap at 0; the 2× clip's local time is retimed (source 20 s → local 10 s).
        #expect(markers.map { fcpTime($0.attribute(forName: "start")?.stringValue).map { Double($0.0) / Double($0.1) } } == [11.5, 0.5, 11])
        #expect(markers.allSatisfy { same(fcpTime($0.attribute(forName: "duration")?.stringValue), (1, 30)) })
        // After the clip's anchored items (DTD order).
        let a1 = try #require(markers.first?.parent as? XMLElement)
        let names = (a1.children ?? []).compactMap(\.name)
        #expect(names.lastIndex(where: { $0 != "marker" })! < names.firstIndex(of: "marker")!)
    }

    // MARK: - OTIO

    func otioJSON() throws -> [String: Any] {
        let data = try OTIOExporter().export(Fixture.timeline, assets: Fixture.assets)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func otioStructureAndExactTimes() throws {
        let root = try otioJSON()
        #expect(root["OTIO_SCHEMA"] as? String == "Timeline.1")
        let stack = try #require(root["tracks"] as? [String: Any])
        #expect(stack["OTIO_SCHEMA"] as? String == "Stack.1")
        let tracks = try #require(stack["children"] as? [[String: Any]])
        #expect(tracks.map { $0["name"] as! String } == ["Main", "Main Audio", "PiP", "Titles", "Captions", "Music"])
        #expect(tracks.map { $0["kind"] as! String } == ["Video", "Audio", "Video", "Video", "Video", "Audio"])

        func frames(_ rt: Any?) -> Double? {
            guard let rt = rt as? [String: Any], rt["OTIO_SCHEMA"] as? String == "RationalTime.1",
                  rt["rate"] as? Double == 30 else { return nil }
            return rt["value"] as? Double
        }
        func range(_ c: [String: Any]) -> (Double, Double)? {
            guard let r = c["source_range"] as? [String: Any], let s = frames(r["start_time"]), let d = frames(r["duration"]) else { return nil }
            return (s, d)
        }

        let main = try #require(tracks[0]["children"] as? [[String: Any]])
        #expect(main.map { $0["OTIO_SCHEMA"] as! String } == ["Clip.2", "Gap.1", "Clip.2", "Clip.2"])
        #expect(main.compactMap(range).map(\.0) == [300, 0, 0, 600])
        #expect(main.compactMap(range).map(\.1) == [90, 30, 90, 60])
        #expect(main.compactMap(range).map(\.1).reduce(0, +) == 270)

        let ref = try #require((main[0]["media_references"] as? [String: Any])?["DEFAULT_MEDIA"] as? [String: Any])
        #expect(ref["OTIO_SCHEMA"] as? String == "ExternalReference.1")
        #expect(ref["target_url"] as? String == "file:///Volumes/Media/My%20Clips/interview.mov")
        let available = try #require(ref["available_range"] as? [String: Any])
        #expect(frames(available["duration"]) == 1800)

        let warp = try #require((main[3]["effects"] as? [[String: Any]])?.first)
        #expect(warp["OTIO_SCHEMA"] as? String == "LinearTimeWarp.1" && warp["time_scalar"] as? Double == 2)

        // PiP: leading gap, then the clip; transform travels in metadata.
        let pip = try #require(tracks[2]["children"] as? [[String: Any]])
        #expect(pip.compactMap(range).map(\.1) == [30, 120])
        let item = try #require(((pip[1]["metadata"] as? [String: Any])?["clipper"] as? [String: Any])?["item"] as? [String: Any])
        let transform = try #require(item["transform"] as? [String: Any])
        #expect((transform["box"] as? [String: Any])?["width"] as? Double == 0.4)
        #expect(item["opacity"] as? Double == 0.9)

        // Music: gain keyframes (ducking) preserved.
        let music = try #require(tracks[5]["children"] as? [[String: Any]])
        let musicItem = try #require(((music[0]["metadata"] as? [String: Any])?["clipper"] as? [String: Any])?["item"] as? [String: Any])
        #expect(((musicItem["gain"] as? [String: Any])?["keys"] as? [Any])?.count == 5)
        #expect((((tracks[5]["metadata"] as? [String: Any])?["clipper"] as? [String: Any])?["track"] as? [String: Any])?["gain"] as? Double == -2)

        // Captions become generator clips with their text.
        let caps = try #require(tracks[4]["children"] as? [[String: Any]])
        let gen = try #require((caps[1]["media_references"] as? [String: Any])?["DEFAULT_MEDIA"] as? [String: Any])
        #expect(gen["OTIO_SCHEMA"] as? String == "GeneratorReference.1" && gen["generator_kind"] as? String == "clipper.caption")
        #expect((gen["parameters"] as? [String: Any])?["text"] as? String == "hi there")
    }

    @Test func otioMarkersOnTheStack() throws {
        let data = try OTIOExporter().export(Fixture.markedTimeline, assets: Fixture.assets)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let markers = try #require((root["tracks"] as? [String: Any])?["markers"] as? [[String: Any]])
        #expect(markers.map { $0["name"] as? String } == ["Chapter: Intro", "Chapter: Gap", "Retake"])
        #expect(markers.allSatisfy { $0["OTIO_SCHEMA"] as? String == "Marker.2" && $0["color"] as? String == "ORANGE" })
        let ranges = markers.compactMap { $0["marked_range"] as? [String: Any] }
        #expect(ranges.compactMap { ($0["start_time"] as? [String: Any])?["value"] as? Double } == [45, 105, 240])
        #expect(ranges.allSatisfy { ($0["duration"] as? [String: Any])?["value"] as? Double == 1 })
    }

    /// Opt-in: reads the file with the real `opentimelineio` package (`CLIPPER_OTIO_PYTHON=1`, needs `uvx`).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLIPPER_OTIO_PYTHON"] == "1" && uvx != nil))
    func otioReadsWithOpenTimelineIO() throws {
        let data = try OTIOExporter().export(Fixture.timeline, assets: Fixture.assets)
        let url = try temporaryFile(data, ext: "otio")
        defer { try? FileManager.default.removeItem(at: url) }
        let script = """
        import sys, opentimelineio as otio
        t = otio.adapters.read_from_file(sys.argv[1])
        d = t.duration()
        # The 2x clip and its mirrored audio.
        warps = [e.time_scalar for c in t.find_clips() for e in c.effects if isinstance(e, otio.schema.LinearTimeWarp)]
        print(d.value, d.rate, len(t.tracks), len(t.video_tracks()), len(t.audio_tracks()), warps)
        """
        let result = try run(uvx!, ["--from", "opentimelineio", "python", "-c", script, url.path])
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("270.0 30.0 6 4 2 [2.0, 2.0]"), "\(result.output)")
    }
}
