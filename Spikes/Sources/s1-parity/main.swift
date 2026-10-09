// S1: are preview and export pixel-identical (WYSIWYG)?
// The same SpikeCompositor renders frames through (a) AVPlayer + AVPlayerItemVideoOutput, i.e. the preview
// path, and (b) AVAssetReaderVideoCompositionOutput → AVAssetWriter, i.e. the export path.
// Pass criteria: composited frames bit-identical between paths; a 4:4:4 master (ProRes 4444) decodes to
// > 45 dB PSNR vs preview (4:2:x delivery codecs lose more on synthetic patterns from chroma subsampling alone,
// see `s1-parity codecs`); playback keeps up at 60 fps.
import AVFoundation
import SpikeKit

@MainActor
func run() async throws {
    print("S1 — compositor preview/export parity")
    let out = Spike.out("s1")
    let scene = try await SceneBuilder.shortScene()
    let fps = 60.0
    // 20 sample frames spread across the 8 s scene, on exact frame boundaries.
    let times = (0..<20).map { CMTime(value: CMTimeValue(Int(Double($0) * 0.39 * fps) + 1), timescale: 60) }

    // (a) Preview path
    let (preview, previewSecs) = try await Spike.time("preview: 20 zero-tolerance seeks") {
        try await Frames.viaPlayer(item: scene.playerItem(), at: times)
    }

    // (b) Export path, at master quality (ProRes 4444) and at delivery quality (HEVC 20 Mb/s)
    let (prores, _) = try await Spike.time("export ProRes 4444") {
        try await Exporter.export(scene, to: out.appendingPathComponent("parity_prores.mov"), codec: .proRes4444, captureTimes: times)
    }
    let (hevc, _) = try await Spike.time("export HEVC 20 Mb/s") {
        try await Exporter.export(scene, to: out.appendingPathComponent("parity_hevc.mov"), codec: .hevc(bitsPerSecond: 20_000_000))
    }
    print(String(format: "  export throughput: ProRes %.0f fps, HEVC %.0f fps (%d frames)",
                 Double(prores.frameCount) / prores.seconds, Double(hevc.frameCount) / hevc.seconds, prores.frameCount))

    let decodedProRes = try await Frames.decode(url: prores.url, at: times)
    let decodedHEVC = try await Frames.decode(url: hevc.url, at: times)

    var rawPSNR: [Double] = [], proresPSNR: [Double] = [], hevcPSNR: [Double] = []
    for t in times {
        guard let p = preview[t] else { print("  ⚠️ no preview frame at \(t.seconds)"); continue }
        if let r = prores.rawFrames[t] { rawPSNR.append(Pixels.psnr(p, r)) }
        if let d = decodedProRes[t] { proresPSNR.append(Pixels.psnr(p, d)) }
        if let d = decodedHEVC[t] { hevcPSNR.append(Pixels.psnr(p, d)) }
    }
    // Save a few frames for eyeballing.
    for (i, t) in times.enumerated() where i % 6 == 0 {
        if let p = preview[t] { Pixels.savePNG(p, to: out.appendingPathComponent(String(format: "preview_%02d.png", i))) }
        if let d = decodedProRes[t] { Pixels.savePNG(d, to: out.appendingPathComponent(String(format: "export_%02d.png", i))) }
    }

    func stats(_ v: [Double]) -> String {
        guard !v.isEmpty else { return "n/a" }
        let finite = v.map { $0.isInfinite ? 99 : $0 }
        return String(format: "min %.1f dB, mean %.1f dB (n=%d, identical=%d)",
                      finite.min()!, finite.reduce(0, +) / Double(finite.count), v.count, v.filter(\.isInfinite).count)
    }
    print("  preview vs raw composited export frame: \(stats(rawPSNR))")
    print("  preview vs decoded ProRes 4444:          \(stats(proresPSNR))")
    print("  preview vs decoded HEVC 20 Mb/s:        \(stats(hevcPSNR))")

    // Real-time playback: play at 1×, sample the video output at 240 Hz, count unique frames.
    let item = scene.playerItem()
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    item.add(output)
    let player = AVPlayer(playerItem: item)
    try await Frames.waitReady(item)
    player.play()
    var seen = Set<Int64>()
    let playStart = ContinuousClock.now
    while ContinuousClock.now - playStart < .seconds(7) {
        let t = output.itemTime(forHostTime: CACurrentMediaTime())
        if output.hasNewPixelBuffer(forItemTime: t) {
            var shown = CMTime.zero
            if output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: &shown) != nil {
                seen.insert(shown.convertScale(60, method: .roundHalfAwayFromZero).value)
            }
        }
        try await Task.sleep(for: .microseconds(4000))
    }
    let reached = player.currentTime().seconds
    player.pause()
    let expected = Int(reached * fps)
    let delivered = seen.count
    let dropRate = 1 - Double(delivered) / Double(max(expected, 1))
    print(String(format: "  playback: reached %.2fs, %d/%d frames delivered (%.1f%% dropped)", reached, delivered, expected, dropRate * 100))

    let minPro = proresPSNR.map { $0.isInfinite ? 99 : $0 }.min() ?? 0
    let rawMin = rawPSNR.map { $0.isInfinite ? 99 : $0 }.min() ?? 0
    Spike.verdict("S1 identical compositing", rawMin >= 99 && rawPSNR.count == times.count, "preview frame == export frame before encoding on \(rawPSNR.count)/\(times.count) samples")
    Spike.verdict("S1 parity", minPro > 45, String(format: "min PSNR preview↔ProRes export %.1f dB (target > 45)", minPro))
    Spike.verdict("S1 realtime", dropRate < 0.02, String(format: "%.1f%% dropped at 60 fps (target < 2%%)", dropRate * 100))
    Spike.writeResult("s1", [
        "previewSeekSeconds": previewSecs, "rawPSNRmin": rawPSNR.map { $0.isInfinite ? 99 : $0 }.min() ?? 0,
        "proresPSNRmin": minPro, "hevcPSNRmin": hevcPSNR.map { $0.isInfinite ? 99 : $0 }.min() ?? 0,
        "exportFpsProRes": Double(prores.frameCount) / prores.seconds, "exportFpsHEVC": Double(hevc.frameCount) / hevc.seconds,
        "playbackDropRate": dropRate, "framesCompared": proresPSNR.count,
    ])
}

if CommandLine.arguments.contains("codecs") { try await runCodecDiagnostics() } else { try await run() }
