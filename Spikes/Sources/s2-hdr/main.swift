// S2: HDR (HLG and PQ, 10-bit BT.2020) → SDR Rec.709.
// Path A, Apple: the compositor declares supportsHDRSourceFrames = false, so AVFoundation converts sources
//         to the Rec.709 composition colour space before we see them.
// Path B, ours: the compositor receives untouched half-float HLG/PQ frames and tone-maps them in our shader.
// We compare A and B (agreement, brightness, clipping), check that preview == export for HDR sources, and
// save frames to eyeball. Real iPhone clips in Fixtures/user/*.mov are included automatically.
import AVFoundation
import SpikeKit

struct Clip { let name: String; let url: URL; let transfer: SourceTransfer }

@MainActor
func frames(_ clip: Clip, compositor: SpikeCompositor.Type, transfer: SourceTransfer, times: [CMTime]) async throws
    -> (export: [CMTime: CVPixelBuffer], preview: [CMTime: CVPixelBuffer])
{
    let comp = AVMutableComposition()
    let duration = try await AVURLAsset(url: clip.url).load(.duration).seconds
    let id = try await SceneBuilder.addTrack(comp, url: clip.url, seconds: min(duration, 5))
    let vc = SceneBuilder.videoComposition(comp, size: CGSize(width: 1920, height: 1080), fps: 30,
                                           layers: [Layer(.track(id, transfer: transfer), fit: .fit)], compositor: compositor,
                                           hdrWorkingSpace: compositor.wantsHDR ? transfer : nil)
    let scene = BuiltScene(composition: comp, videoComposition: vc, duration: comp.duration)
    SpikeCompositor.logFirstSource = true
    let exp = try await Exporter.export(scene, to: Spike.out("s2").appendingPathComponent("tmp.mov"), codec: .proRes4444, captureTimes: times)
    let prev = try await Frames.viaPlayer(item: scene.playerItem(), at: times)
    return (exp.rawFrames, prev)
}

func lumaStats(_ buf: CVPixelBuffer) -> (mean: Double, clipped: Double, crushed: Double) {
    CVPixelBufferLockBaseAddress(buf, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
    let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf), r = CVPixelBufferGetBytesPerRow(buf)
    let p = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
    var sum = 0.0, clipped = 0, crushed = 0, n = 0
    for y in stride(from: 0, to: h, by: 2) { for x in stride(from: 0, to: w, by: 2) {
        let o = y * r + x * 4
        let yv = 0.2126 * Double(p[o + 2]) + 0.7152 * Double(p[o + 1]) + 0.0722 * Double(p[o])
        sum += yv; n += 1
        if yv >= 254 { clipped += 1 }
        if yv <= 1 { crushed += 1 }
    } }
    return (sum / Double(n) / 255, Double(clipped) / Double(n), Double(crushed) / Double(n))
}

@MainActor
func run() async throws {
    print("S2 — HDR → SDR")
    var clips = [Clip(name: "hlg_synthetic", url: Spike.fixture("hdr_hlg_10bit.mov"), transfer: .hlg),
                 Clip(name: "pq_synthetic", url: Spike.fixture("hdr_pq_10bit.mov"), transfer: .pq)]
    let userDir = Spike.fixture("user")
    for url in (try? FileManager.default.contentsOfDirectory(at: userDir, includingPropertiesForKeys: nil)) ?? []
    where ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) {
        let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first
        let desc = try await track?.load(.formatDescriptions).first
        let trc = desc.flatMap { CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String }
        let tf: SourceTransfer = trc == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) ? .hlg
            : trc == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) ? .pq : .sdr
        print("  user clip \(url.lastPathComponent): transfer=\(trc ?? "unknown")")
        if tf != .sdr { clips.append(Clip(name: "user_" + url.deletingPathExtension().lastPathComponent, url: url, transfer: tf)) }
    }

    let times = [0.5, 1.5, 3.0].map { CMTime(seconds: $0, preferredTimescale: 30) }
    var results: [[String: Any]] = []
    var allAgree = true, previewMatches = true, appleMatches = true
    for clip in clips {
        print("• \(clip.name)")
        print("  path A (Apple conversion):"); let a = try await frames(clip, compositor: SpikeCompositor.self, transfer: .sdr, times: times)
        print("  path B (our shader):");       let b = try await frames(clip, compositor: SpikeHDRCompositor.self, transfer: clip.transfer, times: times)
        for (i, t) in times.enumerated() {
            guard let fa = a.export[t], let fb = b.export[t] else { print("  ⚠️ missing frame at \(t.seconds)"); continue }
            let sa = lumaStats(fa), sb = lumaStats(fb), agree = Pixels.psnr(fa, fb)
            let pa = a.preview[t].map { Pixels.psnr($0, fa) } ?? -1
            let pb = b.preview[t].map { Pixels.psnr($0, fb) } ?? -1
            print(String(format: "  t=%.1fs  A: mean %.3f clip %.2f%%  |  B: mean %.3f clip %.2f%%  |  A↔B %.1f dB  |  preview==export A %.0f B %.0f dB",
                         t.seconds, sa.mean, sa.clipped * 100, sb.mean, sb.clipped * 100, agree, min(pa, 99), min(pb, 99)))
            Pixels.savePNG(fa, to: Spike.out("s2").appendingPathComponent("\(clip.name)_\(i)_apple.png"))
            Pixels.savePNG(fb, to: Spike.out("s2").appendingPathComponent("\(clip.name)_\(i)_ours.png"))
            allAgree = allAgree && agree > 25
            previewMatches = previewMatches && pb >= 99
            appleMatches = appleMatches && pa >= 99
            results.append(["clip": clip.name, "t": t.seconds, "appleMean": sa.mean, "oursMean": sb.mean,
                            "appleClipped": sa.clipped, "oursClipped": sb.clipped, "agreementPSNR": min(agree, 99)])
        }
    }
    Spike.verdict("S2 preview==export (our tone mapping)", previewMatches, "our HDR path renders identically in AVPlayer and export")
    print("  ℹ️  Apple's automatic HDR→SDR conversion preview==export: \(appleMatches ? "yes" : "NO — differs between AVPlayer and AVAssetReader")")
    Spike.verdict("S2 shader vs Apple", allAgree, "our tone map is in the same ballpark as Apple's (PSNR > 25 dB); visual check required")
    Spike.writeResult("s2", ["frames": results, "previewMatchesExport": previewMatches, "appleConversionPreviewMatchesExport": appleMatches])
}

try await run()
