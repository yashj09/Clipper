import AVFoundation
import ClipperCore
import Foundation
import Testing
@testable import ClipperEngine

@Suite struct ProxyPolicyTests {
    func video(_ w: Int, _ h: Int, minutes: Double = 1, codec: String = "hvc1", transfer: TransferFunction = .sdr) -> MediaInfo {
        MediaInfo(kind: .video, duration: RationalTime(seconds: minutes * 60), naturalWidth: w, naturalHeight: h, frameRate: 30,
                  transfer: transfer, videoCodec: codec)
    }

    @Test func automaticPicksHeavyMediaOnly() {
        #expect(ProxyGenerator.wantsProxy(video(3840, 2160), policy: .automatic))          // 4K
        #expect(ProxyGenerator.wantsProxy(video(2560, 1440), policy: .automatic))          // 1440p
        #expect(ProxyGenerator.wantsProxy(video(1920, 1080, codec: "apch"), policy: .automatic))   // ProRes
        #expect(ProxyGenerator.wantsProxy(video(1920, 1080, minutes: 45), policy: .automatic))     // long recording
        #expect(!ProxyGenerator.wantsProxy(video(1920, 1080), policy: .automatic))
        #expect(!ProxyGenerator.wantsProxy(video(1920, 1080, transfer: .hlg), policy: .automatic)) // 1080p HDR plays fine
        #expect(!ProxyGenerator.wantsProxy(video(1280, 720, minutes: 120), policy: .always))      // already proxy-sized
        #expect(ProxyGenerator.wantsProxy(video(1920, 1080), policy: .always))
        #expect(!ProxyGenerator.wantsProxy(video(3840, 2160), policy: .never))
        #expect(!ProxyGenerator.wantsProxy(MediaInfo(kind: .audio, duration: RationalTime(seconds: 3600)), policy: .always))
    }

    @Test func sizeKeepsAspectWithEvenSides() {
        #expect(ProxyGenerator.size(for: video(3840, 2160)) == (1280, 720))
        #expect(ProxyGenerator.size(for: video(1080, 1920)) == (720, 1280))
        #expect(ProxyGenerator.size(for: video(3068, 2478)) == (892, 720))     // a screen recording
        #expect(ProxyGenerator.size(for: video(640, 360)) == (640, 360))        // never upscaled
    }

    @Test func settingsDecodeTheNewFieldTolerantly() throws {
        let s = try JSONDecoder().decode(ClipperSettings.self, from: Data(#"{"editing": {"proxyPolicy": "always"}}"#.utf8))
        #expect(s.editing.proxyPolicy == .always)
        let old = try JSONDecoder().decode(ClipperSettings.self, from: Data(#"{"editing": {"snapping": false}}"#.utf8))
        #expect(old.editing.proxyPolicy == .automatic && !old.editing.snapping)
    }
}

/// Proxies of real fixtures keep what the compositor relies on: timing, orientation and colour.
@Suite(.serialized) struct ProxyGeneratorTests {
    /// Presentation times of every video sample (read without decoding), sorted.
    static func frameTimes(_ url: URL) async throws -> [Double] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(out)
        reader.startReading()
        var times: [Double] = []
        while let sb = out.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sb) > 0 else { continue }
            times.append(CMSampleBufferGetPresentationTimeStamp(sb).seconds)
        }
        return times.sorted()
    }

    static func makeProxy(_ source: URL, _ name: String) async throws -> (original: MediaAsset, proxy: MediaAsset) {
        let original = try await MediaProbe.makeAsset(source)
        let out = Fixture.out(name)
        try await ProxyGenerator.make(source: source, info: original.info, to: out)
        #expect(!FileManager.default.fileExists(atPath: out.deletingPathExtension().appendingPathExtension("partial.mov").path))
        return (original, try await MediaProbe.makeAsset(out))
    }

    @Test func iPhoneProxyKeepsTimingOrientationAndHDR() async throws {
        guard let source = Fixture.iPhone else { return }
        let (o, p) = try await Self.makeProxy(source, "proxy-iphone.mov")
        #expect(p.info.transfer == o.info.transfer, "transfer \(p.info.transfer) vs \(o.info.transfer)")
        #expect(p.info.rotation == o.info.rotation && p.info.mirrored == o.info.mirrored)
        #expect(min(p.info.naturalWidth, p.info.naturalHeight) == ProxyGenerator.shortSide)
        #expect(p.info.audioChannels == o.info.audioChannels)
        let a = try await Self.frameTimes(source), b = try await Self.frameTimes(p.url)
        #expect(a.count == b.count, "\(a.count) vs \(b.count) frames")
        #expect(zip(a, b).allSatisfy { abs($0 - $1) < 1e-4 }, "variable frame timing must be kept")

        // Rendered through the compositor (rotation + HLG tone mapping), the proxy frames the picture like the original.
        var asset = o
        let item = Item(range: TimeRange(seconds: 0, 3), content: .media(MediaRef(asset: asset.id, source: TimeRange(seconds: 1, 4))))
        let tl = Timeline(name: "P", canvas: .vertical1080, tracks: [Track(kind: .video, items: [item])])
        let t = RationalTime(seconds: 1.5).roundedToFrame(.fps30).cmTime
        let full = try await CompositionBuilder.build(tl, assets: [asset.id: asset], options: BuildOptions(renderScale: 0.25))
        asset.proxyURL = p.url
        let proxied = try await CompositionBuilder.build(tl, assets: [asset.id: asset], options: BuildOptions(renderScale: 0.25, useProxies: true))
        let x = try #require(try await Pixels.readComposited(full, at: [t])[t])
        let y = try #require(try await Pixels.readComposited(proxied, at: [t])[t])
        let psnr = Pixels.psnr(x, y)
        #expect(psnr > 30, "iPhone proxy vs original at quarter size: \(psnr) dB")
    }

    @Test func hdrFixtureStaysHDR() async throws {
        guard let source = Fixture.url("hdr_pq_10bit.mov") else { return }
        let (o, p) = try await Self.makeProxy(source, "proxy-pq.mov")
        guard min(o.info.naturalWidth, o.info.naturalHeight) > ProxyGenerator.shortSide else { return }
        #expect(p.info.transfer == .pq)
    }

    /// The preview built from the proxy frames the picture like the original (same orientation, same placement).
    @Test func proxyRendersLikeTheOriginal() async throws {
        guard let source = Fixture.url("rotated_marker.mov") else { return }
        var (original, proxy) = try await Self.makeProxy(source, "proxy-rotated.mov")
        #expect(proxy.info.rotation == original.info.rotation)
        let item = Item(range: TimeRange(seconds: 0, 2), content: .media(MediaRef(asset: original.id, source: TimeRange(seconds: 0, 2))))
        let tl = Timeline(name: "P", canvas: .vertical1080, tracks: [Track(kind: .video, items: [item])])
        let t = RationalTime(seconds: 1).roundedToFrame(.fps30).cmTime
        let full = try await CompositionBuilder.build(tl, assets: [original.id: original], options: BuildOptions(renderScale: 0.25))
        original.proxyURL = proxy.url
        let viaProxy = try await CompositionBuilder.build(tl, assets: [original.id: original], options: BuildOptions(renderScale: 0.25, useProxies: true))
        let a = try #require(try await Pixels.readComposited(full, at: [t])[t])
        let b = try #require(try await Pixels.readComposited(viaProxy, at: [t])[t])
        let psnr = Pixels.psnr(a, b)
        #expect(psnr > 28, "proxy vs original at quarter size: \(psnr) dB")
        for region in [NormRect(x: 0.85, y: 0.02, width: 0.1, height: 0.08), NormRect(x: 0.05, y: 0.02, width: 0.1, height: 0.08)] {
            let d = Pixels.mean(a, region) - Pixels.mean(b, region)
            #expect(max(abs(d.x), abs(d.y), abs(d.z)) < 0.05, "region \(region) differs by \(d)")
        }
        // A proxy whose file is gone falls back to the original instead of failing the preview.
        original.proxyURL = Fixture.out("missing-proxy.mov")
        let fallback = try await CompositionBuilder.build(tl, assets: [original.id: original], options: BuildOptions(renderScale: 0.25, useProxies: true))
        let c = try #require(try await Pixels.readComposited(fallback, at: [t])[t])
        #expect(Pixels.psnr(a, c) >= 99)
    }
}
