import AVFoundation
import SpikeKit

/// `s1-parity codecs`: per-codec export speed and preview↔decoded PSNR, to separate codec loss from pipeline bugs.
@MainActor
func runCodecDiagnostics() async throws {
    let out = Spike.out("s1")
    let scene = try await SceneBuilder.shortScene(seconds: 3)
    let times = (0..<6).map { CMTime(value: CMTimeValue(1 + $0 * 30), timescale: 60) }
    let preview = try await Frames.viaPlayer(item: scene.playerItem(), at: times)
    let codecs: [(String, ExportCodec)] = [
        ("prores4444", .proRes4444), ("prores422hq", .proRes422HQ),
        ("hevc_hw_20M", .hevcHW(bitsPerSecond: 20_000_000)), ("h264_20M", .h264(bitsPerSecond: 20_000_000)),
        ("hevc_default_20M", .hevc(bitsPerSecond: 20_000_000)),
    ]
    for (name, codec) in codecs {
        do {
            let r = try await Exporter.export(scene, to: out.appendingPathComponent("diag_\(name).mov"), codec: codec)
            let dec = try await Frames.decode(url: r.url, at: times)
            let ps = times.compactMap { t in preview[t].flatMap { p in dec[t].map { Pixels.psnr(p, $0) } } }
            let shift = times.compactMap { t in preview[t].flatMap { p in dec[t].map { Pixels.meanRGB($0) - Pixels.meanRGB(p) } } }
            let avgShift = shift.reduce(SIMD3<Double>(0, 0, 0), +) / Double(max(shift.count, 1))
            print(String(format: "  %-18@ %6.0f fps   PSNR min %.1f dB   mean RGB shift (%.4f, %.4f, %.4f)",
                         name, Double(r.frameCount) / r.seconds, ps.min() ?? 0, avgShift.x, avgShift.y, avgShift.z))
        } catch { print("  \(name): ERROR \(error)") }
    }
}
