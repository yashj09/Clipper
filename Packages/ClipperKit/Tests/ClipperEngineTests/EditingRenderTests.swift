import AVFoundation
import ClipperCore
import Foundation
import Testing
@testable import ClipperEngine

@Suite struct EditingGeometryTests {
    @Test func flippingSwapsCornersNotTheSource() {
        let g = LayerGeometry(corners: [SIMD2(0, 0), SIMD2(10, 0), SIMD2(0, 20), SIMD2(10, 20)], sourceRect: .full)
        #expect(g.flipped(horizontally: true, vertically: false).corners == [SIMD2(10, 0), SIMD2(0, 0), SIMD2(10, 20), SIMD2(0, 20)])
        #expect(g.flipped(horizontally: false, vertically: true).corners == [SIMD2(0, 20), SIMD2(10, 20), SIMD2(0, 0), SIMD2(10, 0)])
        #expect(g.flipped(horizontally: false, vertically: false) == g)
    }

    @Test func envelopeIsPiecewiseLinearAndHeld() {
        let e: [OpacityEnvelope.Point] = [.init(1, 0), .init(2, 1), .init(3, 0)]
        #expect(OpacityEnvelope.value(e, at: 0) == 0 && OpacityEnvelope.value(e, at: 1.5) == 0.5)
        #expect(OpacityEnvelope.value(e, at: 2) == 1 && OpacityEnvelope.value(e, at: 9) == 0)
        #expect(OpacityEnvelope.value([], at: 5) == 1)
    }

    @Test func transitionsClampAndFindTheOutgoingClip() {
        let rate = FrameRate.fps30
        let a = Item(range: TimeRange(seconds: 0, 1), content: .solid(.black))
        var b = Item(range: TimeRange(seconds: 1, 5), content: .solid(.white), transition: Transition(.crossDissolve, duration: RationalTime(seconds: 2)))
        let r = Transitions.resolve(b, after: a, rate: rate)
        #expect(r?.outgoing?.id == a.id && r?.duration == RationalTime(seconds: 1))   // no longer than the outgoing clip
        b.range = TimeRange(seconds: 3, 7)                                               // a gap: fades from the background
        #expect(Transitions.resolve(b, after: a, rate: rate)?.outgoing == nil)
        #expect(Transitions.resolve(a, after: nil, rate: rate) == nil)
    }

    @Test func tailUsesTheHandleOrHoldsTheLastFrame() {
        let ref = MediaRef(asset: UUID(), source: TimeRange(seconds: 2, 4))
        let withHandle = Transitions.tailSource(ref, assetDuration: RationalTime(seconds: 10), frameRate: 30, length: RationalTime(seconds: 1))
        #expect(!withHandle.isHold && withHandle.range == TimeRange(seconds: 4, 5))
        let atEnd = Transitions.tailSource(ref, assetDuration: RationalTime(seconds: 4.5), frameRate: 30, length: RationalTime(seconds: 1))
        // Not enough media after the out-point: hold the clip's own last frame.
        #expect(atEnd.isHold && atEnd.range.end == RationalTime(seconds: 4) && atEnd.range.duration.seconds < 0.04)
    }
}

/// Rendered through the real compositor (export path) on the fixtures.
@Suite(.serialized) struct EditingRenderTests {
    static func assets() async throws -> (MediaAsset, MediaAsset)? {
        guard let a = Fixture.url("bg_1080x1920_60.mov"), let b = Fixture.url("overlay_1280x720_30.mov") else { return nil }
        return (try await MediaProbe.makeAsset(a), try await MediaProbe.makeAsset(b))
    }

    static func clip(_ asset: MediaAsset, _ start: Double, _ end: Double, src: Double = 0) -> Item {
        Item(name: asset.name, range: TimeRange(seconds: start, end), content: .media(MediaRef(asset: asset.id, source: TimeRange(seconds: src, src + end - start))))
    }

    static func frame(_ items: [Item], _ assets: [MediaAsset], at seconds: Double) async throws -> CVPixelBuffer {
        let tl = Timeline(name: "R", canvas: .vertical1080, tracks: [Track(kind: .video, items: items)])
        let built = try await CompositionBuilder.build(tl, assets: Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) }),
                                                       options: BuildOptions(renderScale: 0.25))
        let t = RationalTime(seconds: seconds).roundedToFrame(.fps30).cmTime
        return try #require(try await Pixels.readComposited(built, at: [t])[t])
    }

    static let all = NormRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)

    @Test func disabledClipsAreNotRendered() async throws {
        guard let (a, _) = try await Self.assets() else { return }
        var item = Self.clip(a, 0, 2)
        item.enabled = false
        let f = try await Self.frame([item], [a], at: 1)
        #expect(Pixels.mean(f, Self.all).x < 0.01)
    }

    @Test func colorCorrectionChangesTheImage() async throws {
        guard let (_, b) = try await Self.assets() else { return }
        let plain = try await Self.frame([Self.clip(b, 0, 2)], [b], at: 1)
        var grey = Self.clip(b, 0, 2)
        grey.color.saturation = -1
        let g = try await Self.frame([grey], [b], at: 1)
        let m = Pixels.mean(g, NormRect(x: 0.1, y: 0.4, width: 0.8, height: 0.2))
        #expect(abs(m.x - m.y) < 0.02 && abs(m.y - m.z) < 0.02, "black & white should be neutral: \(m)")
        // Colour bars sit at 0 or near 1 (nothing to brighten), so check a stop down.
        var darker = Self.clip(b, 0, 2)
        darker.color.exposure = -1
        let dk = try await Self.frame([darker], [b], at: 1)
        let p = Pixels.mean(plain, NormRect(x: 0.1, y: 0.4, width: 0.8, height: 0.2)), q = Pixels.mean(dk, NormRect(x: 0.1, y: 0.4, width: 0.8, height: 0.2))
        #expect(q.x + q.y + q.z < p.x + p.y + p.z - 0.2, "−1 stop should darken: \(p) → \(q)")
        var flipped = Self.clip(b, 0, 2)
        flipped.transform.flipH = true
        let fl = try await Self.frame([flipped], [b], at: 1)
        let left = NormRect(x: 0.05, y: 0.45, width: 0.1, height: 0.1), right = NormRect(x: 0.85, y: 0.45, width: 0.1, height: 0.1)
        let d = Pixels.mean(fl, left) - Pixels.mean(plain, right)
        #expect(max(abs(d.x), abs(d.y), abs(d.z)) < 0.06, "flipped left edge should look like the original's right edge: \(d)")
    }

    @Test func crossDissolveMixesBothClips() async throws {
        guard let (a, b) = try await Self.assets() else { return }
        var incoming = Self.clip(b, 2, 4)
        incoming.transition = Transition(.crossDissolve, duration: RationalTime(seconds: 1))
        let mixed = try await Self.frame([Self.clip(a, 0, 2), incoming], [a, b], at: 2.5)
        // References: the outgoing clip continuing (its handle) and the incoming clip alone, at the same instant.
        let outgoing = try await Self.frame([Self.clip(a, 0, 3)], [a], at: 2.5)
        let alone = try await Self.frame([Self.clip(b, 2, 4)], [b], at: 2.5)
        let m = Pixels.mean(mixed, Self.all), x = Pixels.mean(outgoing, Self.all), y = Pixels.mean(alone, Self.all)
        let expected = (x + y) / 2
        #expect(max(abs(m.x - expected.x), abs(m.y - expected.y), abs(m.z - expected.z)) < 0.04, "half-way: \(m) vs \(expected)")
        // Before and after the transition, each clip is shown alone.
        let after = try await Self.frame([Self.clip(a, 0, 2), incoming], [a, b], at: 3.5)
        #expect(Pixels.psnr(after, try await Self.frame([Self.clip(b, 2, 4)], [b], at: 3.5)) > 40)
    }

    @Test func dissolveIntoAStillKeepsTheOutgoingClip() async throws {
        guard let (a, b) = try await Self.assets() else { return }
        let png = Fixture.out("dissolve-still.png")
        try StillRenderer.writePNG(try await StillRenderer.still(of: b, at: RationalTime(seconds: 1)), to: png)
        let still = try await MediaProbe.makeAsset(png)
        var incoming = Item(range: TimeRange(seconds: 2, 4), content: .image(still.id))
        incoming.transition = Transition(.crossDissolve, duration: RationalTime(seconds: 1))
        let mixed = try await Self.frame([Self.clip(a, 0, 2), incoming], [a, still], at: 2.5)
        let outgoing = try await Self.frame([Self.clip(a, 0, 3)], [a], at: 2.5)
        let alone = try await Self.frame([Item(range: TimeRange(seconds: 2, 4), content: .image(still.id))], [still], at: 2.5)
        let m = Pixels.mean(mixed, Self.all), e = (Pixels.mean(outgoing, Self.all) + Pixels.mean(alone, Self.all)) / 2
        #expect(max(abs(m.x - e.x), abs(m.y - e.y), abs(m.z - e.z)) < 0.04, "half-way into a still: \(m) vs \(e)")
    }

    @Test func dipToBlackIsBlackHalfWay() async throws {
        guard let (a, b) = try await Self.assets() else { return }
        var incoming = Self.clip(b, 2, 4)
        incoming.transition = Transition(.dipToBlack, duration: RationalTime(seconds: 1))
        let mid = try await Self.frame([Self.clip(a, 0, 2), incoming], [a, b], at: 2.5)
        #expect(Pixels.mean(mid, Self.all).x < 0.02)
        let early = try await Self.frame([Self.clip(a, 0, 2), incoming], [a, b], at: 2.1)
        #expect(Pixels.mean(early, Self.all).x > 0.05, "the outgoing clip is still visible early in the dip")
    }
}

@Suite struct StillRendererTests {
    @Test func stillOfTheRotatedFixtureIsUpright() async throws {
        guard let url = Fixture.url("rotated_marker.mov") else { return }
        let asset = try await MediaProbe.makeAsset(url)
        let image = try await StillRenderer.still(of: asset, at: RationalTime(seconds: 1))
        #expect(image.width == asset.info.displayWidth / 2 * 2 && image.height == asset.info.displayHeight / 2 * 2)
        let out = Fixture.out("still.png")
        try StillRenderer.writePNG(image, to: out)
        let probed = try await MediaProbe.makeAsset(out)
        #expect(probed.info.kind == .image && probed.info.displayWidth == image.width)
    }
}

@Suite struct ViewerGeometryTests {
    @Test func quadsAndHitTesting() {
        let asset = MediaAsset(key: AssetKey("a"), name: "A", url: URL(fileURLWithPath: "/tmp/a.mov"),
                               info: MediaInfo(kind: .video, duration: RationalTime(seconds: 10), naturalWidth: 1920, naturalHeight: 1080))
        var overlay = Item(range: TimeRange(seconds: 0, 5), content: .media(MediaRef(asset: asset.id, source: TimeRange(seconds: 0, 5))))
        overlay.transform.box = NormSize(0.5, 0.25)
        overlay.transform.position = .constant(NormPoint(0.25, 0.25))
        let base = Item(range: TimeRange(seconds: 0, 5), content: .media(MediaRef(asset: asset.id, source: TimeRange(seconds: 0, 5))))
        let tl = Timeline(name: "T", canvas: .vertical1080, tracks: [Track(kind: .video, items: [base]), Track(kind: .overlay, items: [overlay])])
        let assets = [asset.id: asset]
        let q = ViewerGeometry.quad(of: overlay, in: tl, assets: assets, at: RationalTime(seconds: 1))!
        #expect(q[0] == SIMD2(0, 240) && q[3] == SIMD2(540, 720))
        // The overlay is on top where it is; elsewhere the full-frame base clip is hit.
        #expect(ViewerGeometry.item(at: SIMD2(270, 480), in: tl, assets: assets, time: RationalTime(seconds: 1))?.id == overlay.id)
        #expect(ViewerGeometry.item(at: SIMD2(800, 1500), in: tl, assets: assets, time: RationalTime(seconds: 1))?.id == base.id)
        #expect(ViewerGeometry.item(at: SIMD2(800, 1500), in: tl, assets: assets, time: RationalTime(seconds: 7)) == nil)
        // Rotated quads.
        let diamond = [SIMD2(50.0, 0), SIMD2(100.0, 50), SIMD2(0.0, 50), SIMD2(50.0, 100)]
        #expect(ViewerGeometry.contains(diamond, SIMD2(50, 50)) && !ViewerGeometry.contains(diamond, SIMD2(5, 5)))
    }

    @Test func assigningRespectsKeyframes() {
        let half = RationalTime(value: 1, scale: 60)
        #expect(Param.constant(1.0).assigning(2, at: RationalTime(seconds: 1), tolerance: half) == .constant(2))
        let animated = Param.constant(1.0).setting(1, at: .zero, tolerance: half).setting(3, at: RationalTime(seconds: 2), tolerance: half)
        let out = animated.assigning(5, at: RationalTime(seconds: 1), tolerance: half)
        #expect(out.keys.count == 3 && out.value(at: RationalTime(seconds: 1)) == 5)
    }
}
