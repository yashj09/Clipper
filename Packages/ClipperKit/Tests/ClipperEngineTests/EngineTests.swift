import AVFoundation
import ClipperCore
import Foundation
import Testing
@testable import ClipperEngine

// MARK: - Fixtures

enum Fixture {
    static let root: URL? = {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Fixtures/bg_1080x1920_60.mov").path) { return dir }
            dir.deleteLastPathComponent()
        }
        return nil
    }()
    static func url(_ name: String) -> URL? {
        guard let u = root?.appendingPathComponent("Fixtures/\(name)"), FileManager.default.fileExists(atPath: u.path) else { return nil }
        return u
    }
    static var available: Bool { root != nil }
    static var iPhone: URL? {
        guard let dir = root?.appendingPathComponent("Fixtures/user") else { return nil }
        return (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .first { ["mov", "mp4"].contains($0.pathExtension.lowercased()) }
    }
    static func out(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ClipperEngineTests", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }
}

// MARK: - Pixel helpers

enum Pixels {
    static let bgra: [String: any Sendable] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                               kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()]

    static func psnr(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Double {
        let w = CVPixelBufferGetWidth(a), h = CVPixelBufferGetHeight(a)
        guard w == CVPixelBufferGetWidth(b), h == CVPixelBufferGetHeight(b) else { return -1 }
        CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let pa = CVPixelBufferGetBaseAddress(a)!.assumingMemoryBound(to: UInt8.self)
        let pb = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
        let ra = CVPixelBufferGetBytesPerRow(a), rb = CVPixelBufferGetBytesPerRow(b)
        var sum = 0.0
        for y in 0..<h { for x in 0..<w { for c in 0..<3 { let d = Double(pa[y * ra + x * 4 + c]) - Double(pb[y * rb + x * 4 + c]); sum += d * d } } }
        let mse = sum / Double(w * h * 3)
        return mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
    }

    /// Mean (r, g, b) in 0…1 of a normalized region.
    static func mean(_ buf: CVPixelBuffer, _ r: NormRect) -> SIMD3<Double> {
        CVPixelBufferLockBaseAddress(buf, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf), row = CVPixelBufferGetBytesPerRow(buf)
        let p = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        var acc = SIMD3<Double>(0, 0, 0), n = 0.0
        for y in Int(r.y * Double(h))..<Int((r.y + r.height) * Double(h)) {
            for x in Int(r.x * Double(w))..<Int((r.x + r.width) * Double(w)) {
                let o = y * row + x * 4
                acc += SIMD3(Double(p[o + 2]), Double(p[o + 1]), Double(p[o])); n += 1
            }
        }
        return acc / max(n, 1) / 255
    }

    /// Composited frames via the export path (AVAssetReaderVideoCompositionOutput), before encoding.
    static func readComposited(_ built: BuiltComposition, at times: [CMTime]) async throws -> [CMTime: CVPixelBuffer] {
        let reader = try AVAssetReader(asset: built.composition)
        let out = AVAssetReaderVideoCompositionOutput(videoTracks: try await built.composition.loadTracks(withMediaType: .video),
                                                      videoSettings: bgra)
        out.videoComposition = built.videoComposition
        reader.add(out)
        reader.startReading()
        var result: [CMTime: CVPixelBuffer] = [:]
        let wanted = times.sorted()
        var i = 0
        while i < wanted.count, let sb = out.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            while i < wanted.count, wanted[i] < pts { i += 1 }
            if i < wanted.count, wanted[i] == pts { result[wanted[i]] = sb.imageBuffer; i += 1 }
        }
        reader.cancelReading()
        return result
    }

    /// Frames via the preview path (AVPlayer + AVPlayerItemVideoOutput, zero-tolerance seeks).
    @MainActor static func preview(_ built: BuiltComposition, at times: [CMTime]) async throws -> [CMTime: CVPixelBuffer] {
        let item = built.makePlayerItem()
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: bgra)
        item.add(output)
        let player = AVPlayer(playerItem: item)
        let deadline = ContinuousClock.now + .seconds(10)
        while item.status != .readyToPlay {
            if item.status == .failed { throw item.error! }
            if ContinuousClock.now > deadline { throw CocoaError(.executableLoad) }
            try await Task.sleep(for: .milliseconds(10))
        }
        var result: [CMTime: CVPixelBuffer] = [:]
        for t in times {
            await player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
            let end = ContinuousClock.now + .seconds(3)
            while ContinuousClock.now < end {
                if output.hasNewPixelBuffer(forItemTime: t) {
                    var shown = CMTime.invalid
                    // Only accept the frame actually displayed for `t`: right after loading, the player may still
                    // vend the frame it decoded at 0 for the first seek.
                    if let px = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: &shown), shown == t {
                        result[t] = px; break
                    }
                }
                try await Task.sleep(for: .milliseconds(2))
            }
            if result[t] == nil { print("preview: timeout at \(t.seconds)") }
        }
        _ = player
        return result
    }
}

// MARK: - Unit tests (no media needed)

@Suite struct GeometryTests {
    let canvas = SIMD2<Double>(1080, 1920)

    @Test func fillCropsSourceToBoxAspect() {
        // 16:9 source filling a 9:16 canvas → a centred vertical strip of the source is visible.
        let g = LayerGeometry.media(transform: Transform(fit: .fill), at: .zero, canvas: canvas, sourceSize: SIMD2(1920, 1080))
        #expect(g.corners[0] == SIMD2(0, 0) && g.corners[3] == SIMD2(1080, 1920))
        #expect(abs(g.sourceRect.width - (1080.0 * 1080 / 1920) / 1920) < 1e-9)
        #expect(abs(g.sourceRect.x + g.sourceRect.width / 2 - 0.5) < 1e-9)
    }

    @Test func fitLetterboxes() {
        let g = LayerGeometry.media(transform: Transform(fit: .fit), at: .zero, canvas: canvas, sourceSize: SIMD2(1920, 1080))
        let height = g.corners[2].y - g.corners[0].y
        #expect(abs(height - 1080 * 1080 / 1920) < 1e-6)
        #expect(g.sourceRect == .full)
    }

    @Test func focusIsClampedInsideSource() {
        var tr = Transform(fit: .fill)
        tr.focus = .constant(NormPoint(0, 0.5))   // far left: visible strip must start at x = 0, not go negative
        let g = LayerGeometry.media(transform: tr, at: .zero, canvas: canvas, sourceSize: SIMD2(1920, 1080))
        #expect(g.sourceRect.x == 0)
    }

    @Test func zoomTightensVisibleRegion() {
        var tr = Transform(fit: .fill)
        tr.zoom = .constant(2)
        let g1 = LayerGeometry.media(transform: Transform(fit: .fill), at: .zero, canvas: canvas, sourceSize: SIMD2(1080, 1920))
        let g2 = LayerGeometry.media(transform: tr, at: .zero, canvas: canvas, sourceSize: SIMD2(1080, 1920))
        #expect(abs(g2.sourceRect.width - g1.sourceRect.width / 2) < 1e-9)
    }

    @Test func boxRotationIsClockwise() {
        var tr = Transform(box: NormSize(0.5, 0.25), fit: .stretch)
        tr.rotation = .constant(90)
        let g = LayerGeometry.media(transform: tr, at: .zero, canvas: canvas, sourceSize: SIMD2(100, 100))
        // Top-left corner of the box rotates 90° clockwise around the centre → ends up top-right (y-down space).
        #expect(g.corners[0].x > 540 && g.corners[0].y < 960)
    }

    @Test func orientationMapping() {
        let o = Orientation(rotation: 90, mirrored: false)
        // Display top-right corner (1, 0) comes from the natural top-left (0, 0) for a 90° clockwise display rotation.
        #expect(o.textureCoordinate(SIMD2(1, 0)) == SIMD2(0, 0))
        #expect(Orientation(rotation: 180, mirrored: false).textureCoordinate(SIMD2(0, 0)) == SIMD2(1, 1))
        #expect(MediaProbe.orientation(of: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)).rotation == 90)
        #expect(MediaProbe.orientation(of: .identity).rotation == 0)
    }
}

@Suite struct TextTests {
    @Test func wrapsWithinMaxWidth() {
        let style = TextStyle(size: 0.05, maxWidth: 0.5)
        let words = "this caption is long enough that it must wrap onto more lines".split(separator: " ").map(String.init)
        let layout = TextRenderer.layout(words: words, style: style, canvasWidth: 1080, canvasHeight: 1920)
        #expect(layout.lines.count > 1)
        #expect(layout.lines.allSatisfy { $0.width <= 0.5 * 1080 + 1 })
    }

    @Test func highlightChangesPixels() {
        let style = TextStyle(highlight: .init(color: RGBA(1, 0.85, 0.1)))
        let words = ["hello", "world"]
        let a = TextRenderer.render(words: words, style: style, canvasWidth: 1080, canvasHeight: 1920, options: .init(activeWord: 0))
        let b = TextRenderer.render(words: words, style: style, canvasWidth: 1080, canvasHeight: 1920, options: .init(activeWord: 1))
        #expect(a != nil && b != nil)
        #expect(a!.dataProvider!.data! as Data != b!.dataProvider!.data! as Data)
    }

    @Test func subtitlesFormat() {
        var tl = Timeline(name: "s", canvas: .vertical1080)
        tl.tracks = [Track(kind: .caption, items: [
            Item(range: TimeRange(seconds: 1.5, 3.25), content: .caption(CaptionContent(words: [
                .init(text: "Hello", start: .zero, end: RationalTime(seconds: 0.5)), .init(text: "there", start: RationalTime(seconds: 0.5), end: RationalTime(seconds: 1))], style: "c")))])]
        #expect(Subtitles.srt(tl) == "1\n00:00:01,500 --> 00:00:03,250\nHello there\n")
        #expect(Subtitles.vtt(tl).hasPrefix("WEBVTT\n\n00:00:01.500 --> 00:00:03.250\nHello there"))
    }
}

// MARK: - Integration tests (need Fixtures/; run scripts/make-fixtures.sh)

@Suite(.enabled(if: Fixture.available), .serialized) struct EngineIntegrationTests {
    @Test func probeFixtures() async throws {
        let bg = try await MediaProbe.probe(Fixture.url("bg_1080x1920_60.mov")!)
        #expect(bg.displayWidth == 1080 && bg.displayHeight == 1920)
        #expect(abs(bg.frameRate - 60) < 0.01 && !bg.isVFR && bg.transfer == .sdr && bg.hasAudio)
        let rot = try await MediaProbe.probe(Fixture.url("rotated_marker.mov")!)
        #expect(rot.rotation == 90 && rot.displayWidth == 360 && rot.displayHeight == 640)
        let hlg = try await MediaProbe.probe(Fixture.url("hdr_hlg_10bit.mov")!)
        #expect(hlg.transfer == .hlg)
        if let phone = Fixture.iPhone {
            let p = try await MediaProbe.probe(phone)
            #expect(p.rotation == 90 && p.transfer == .hlg && p.isVFR)
        }
    }

    @Test func assetKeyIsStableAndDistinct() async throws {
        let a = try await MediaProbe.makeAsset(Fixture.url("bg_1080x1920_60.mov")!)
        let b = try await MediaProbe.makeAsset(Fixture.url("bg_1080x1920_60.mov")!)
        let c = try await MediaProbe.makeAsset(Fixture.url("overlay_1280x720_30.mov")!)
        #expect(a.key == b.key && a.key != c.key)
    }

    /// A realistic short: background clip, rotated phone clip, HDR clip, PiP overlay with keyframes, title, captions.
    func makeShort() async throws -> (Timeline, [AssetID: MediaAsset]) {
        var assets: [AssetID: MediaAsset] = [:]
        func add(_ name: String) async throws -> MediaAsset {
            let a = try await MediaProbe.makeAsset(Fixture.url(name)!); assets[a.id] = a; return a
        }
        let bg = try await add("bg_1080x1920_60.mov"), pip = try await add("overlay_1280x720_30.mov")
        let rot = try await add("rotated_marker.mov"), hdr = try await add("hdr_hlg_10bit.mov")
        func media(_ a: MediaAsset, _ start: Double, _ end: Double, src: Double = 0, transform: Transform = .fullFrame) -> Item {
            Item(name: a.name, range: TimeRange(seconds: start, end),
                 content: .media(MediaRef(asset: a.id, source: TimeRange(seconds: src, src + end - start))), transform: transform)
        }
        var pipT = Transform(box: NormSize(0.8, 0.25), position: .constant(NormPoint(0.5, 0.2)), fit: .fill)
        pipT.zoom = .keyframes([Keyframe(.zero, 1), Keyframe(RationalTime(seconds: 2), 1.3)])
        pipT.rotation = .keyframes([Keyframe(.zero, -5), Keyframe(RationalTime(seconds: 2), 5)])
        var title = Item(name: "Title", range: TimeRange(seconds: 0, 2.5), content: .text(TextContent(text: "Clipper engine test", style: "title")))
        title.transform.position = .constant(NormPoint(0.5, 0.1))
        let capWords = ["captions", "follow", "every", "word"].enumerated().map {
            CaptionContent.Word(text: $0.element, start: RationalTime(seconds: Double($0.offset) * 0.4), end: RationalTime(seconds: Double($0.offset + 1) * 0.4))
        }
        var caption = Item(name: "Cap", range: TimeRange(seconds: 1, 3), content: .caption(CaptionContent(words: capWords, style: "caption")))
        caption.transform.position = .constant(NormPoint(0.5, 0.75))
        let tl = Timeline(name: "engine-test", canvas: Canvas(width: 1080, height: 1920, frameRate: .fps30), tracks: [
            Track(kind: .video, items: [media(bg, 0, 3), media(rot, 3, 5.5), media(hdr, 5.5, 7.5)]),
            Track(kind: .overlay, items: [media(pip, 0.5, 4, transform: pipT)]),
            Track(kind: .title, items: [title]),
            Track(kind: .caption, items: [caption]),
        ], styles: [
            "title": TextStyle(size: 0.04, stroke: .black, strokeWidth: 0.06, box: .init(color: RGBA(0, 0, 0, 0.5))),
            "caption": TextStyle(size: 0.05, uppercase: true, highlight: .init(color: RGBA(1, 0.85, 0.1)), animation: .pop),
        ])
        #expect(tl.validate(assetDurations: assets.mapValues(\.info.duration)).filter { $0.severity == .error }.isEmpty)
        return (tl, assets)
    }

    @Test @MainActor func previewMatchesExportBitForBit() async throws {
        let (tl, assets) = try await makeShort()
        let built = try await CompositionBuilder.build(tl, assets: assets)
        #expect(abs(built.duration.seconds - 7.5) < 0.001)
        let times = stride(from: 0.2, to: 7.4, by: 0.6).map { RationalTime(seconds: $0).roundedToFrame(.fps30).cmTime }
        let exported = try await Pixels.readComposited(built, at: times)
        let previewed = try await Pixels.preview(built, at: times)
        var worst = 99.0
        for t in times {
            guard let e = exported[t], let p = previewed[t] else { Issue.record("missing frame at \(t.seconds)"); continue }
            let v = Pixels.psnr(e, p)
            if v < 99 { print("parity t=\(t.seconds): \(v) dB") }
            worst = min(worst, v)
        }
        #expect(worst >= 99, "preview vs export PSNR \(worst)")
    }

    @Test func rotatedClipIsUpright() async throws {
        let (tl, assets) = try await makeShort()
        let built = try await CompositionBuilder.build(tl, assets: assets)
        let t = RationalTime(seconds: 4).roundedToFrame(.fps30).cmTime
        let frame = try #require(try await Pixels.readComposited(built, at: [t])[t])
        // Natural top-left marker → displayed top-right after the 90° clockwise rotation; the 9:16 clip fills the canvas.
        let topRight = Pixels.mean(frame, NormRect(x: 0.85, y: 0.02, width: 0.1, height: 0.08))
        let topLeft = Pixels.mean(frame, NormRect(x: 0.05, y: 0.02, width: 0.1, height: 0.08))
        #expect(topRight.x > 0.6 && topRight.y < 0.3, "expected red top-right, got \(topRight)")
        #expect(topLeft.x < 0.7 && abs(topLeft.x - topLeft.y) < 0.1, "expected grey top-left, got \(topLeft)")
    }

    @Test func sdrSourcesAreUntouchedByHDRNeighbours() async throws {
        // The same SDR frame must render identically whether or not an HDR clip is also in the composition.
        let bgA = try await MediaProbe.makeAsset(Fixture.url("bg_1080x1920_60.mov")!)
        let hdr = try await MediaProbe.makeAsset(Fixture.url("hdr_hlg_10bit.mov")!)
        func tl(withHDR: Bool) -> Timeline {
            var tracks = [Track(kind: .video, items: [Item(range: TimeRange(seconds: 0, 2),
                content: .media(MediaRef(asset: bgA.id, source: TimeRange(seconds: 0, 2))))])]
            if withHDR {
                tracks.append(Track(kind: .overlay, items: [Item(range: TimeRange(seconds: 0, 2),
                    content: .media(MediaRef(asset: hdr.id, source: TimeRange(seconds: 0, 2))), opacity: .constant(0.0001))]))
            }
            return Timeline(name: "x", canvas: .vertical1080, tracks: tracks)
        }
        let assets = [bgA.id: bgA, hdr.id: hdr]
        let t = CMTime(value: 30, timescale: 30)
        let a = try await Pixels.readComposited(try await CompositionBuilder.build(tl(withHDR: false), assets: assets), at: [t])[t]!
        let b = try await Pixels.readComposited(try await CompositionBuilder.build(tl(withHDR: true), assets: assets), at: [t])[t]!
        #expect(Pixels.psnr(a, b) >= 99)
    }

    @Test func textOnlyTimelineRenders() async throws {
        var item = Item(name: "T", range: TimeRange(seconds: 0, 2), content: .text(TextContent(text: "Only text", style: "t")))
        item.transform.position = .constant(.center)
        let tl = Timeline(name: "text", canvas: .square1080, tracks: [Track(kind: .title, items: [item])],
                          styles: ["t": TextStyle(size: 0.1, shadow: nil)])
        let built = try await CompositionBuilder.build(tl, assets: [:])
        #expect(abs(built.duration.seconds - 2) < 0.001)
        let t = CMTime(value: 1, timescale: 1)
        let frame = try #require(try await Pixels.readComposited(built, at: [t])[t])
        #expect(Pixels.mean(frame, NormRect(x: 0.2, y: 0.45, width: 0.6, height: 0.1)).x > 0.1)   // white text over black
        #expect(Pixels.mean(frame, NormRect(x: 0, y: 0, width: 0.1, height: 0.1)).x < 0.01)
    }

    @Test func exportShortsPresetProducesValidFile() async throws {
        let (tl, assets) = try await makeShort()
        let url = Fixture.out("short.mp4")
        let result = try await Exporter.export(tl, assets: assets, preset: ExportPreset.named("shorts-1080x1920")!, to: url)
        let info = try await MediaProbe.probe(url)
        #expect(info.displayWidth == 1080 && info.displayHeight == 1920)
        #expect(abs(info.duration.seconds - 7.5) < 0.05)
        #expect(info.hasAudio && info.videoCodec == "avc1")
        #expect(result.sidecars.contains { $0.pathExtension == "srt" })
        #expect(Double(result.frames) / result.seconds > 60, "export ran at \(Double(result.frames) / result.seconds) fps")
    }

    @Test func exportIsLoudnessNormalized() async throws {
        let (tl, assets) = try await makeShort()
        let before = try #require(try await Exporter.measureMix(tl, assets: assets))
        let url = Fixture.out("loud.mp4")
        let result = try await Exporter.export(tl, assets: assets, preset: ExportPreset.named("shorts-1080x1920")!, to: url)
        let after = try await AudioFileLoudness.measure(url: url)
        print("loudness: mix \(before.integrated) LUFS → file \(after.integrated) LUFS, TP \(after.truePeak) dBTP, gain \(result.appliedGain ?? 0)")
        #expect(abs(after.integrated - -14) < 0.5)
        #expect(after.truePeak < -0.5)   // -1 dBTP ceiling; AAC adds a little overshoot
    }

    @Test func alphaExportKeepsTransparency() async throws {
        var item = Item(range: TimeRange(seconds: 0, 1), content: .text(TextContent(text: "Overlay", style: "t")))
        item.transform.position = .constant(.center)
        let tl = Timeline(name: "alpha", canvas: Canvas(width: 640, height: 360), tracks: [Track(kind: .title, items: [item])],
                          styles: ["t": TextStyle(size: 0.15, shadow: nil)])
        let url = Fixture.out("alpha.mov")
        _ = try await Exporter.export(tl, assets: [:], preset: ExportPreset.named("overlay-prores4444")!, to: url)
        #expect(try await MediaProbe.probe(url).hasAlpha)
    }
}
