// S5: long media. A 30-minute 1080p60 HEVC recording (2 s GOP, like OBS or a phone).
//  1. Proxy generation: AVAssetReader → AVAssetWriter, HEVC 1280×720, keyframe every 0.5 s, VideoToolbox.
//  2. Scrubbing: frame-accurate (zero-tolerance) AVPlayer seek latency, original vs proxy, at random times.
// Pass: proxy ≥ 15× realtime; proxy seek median < 100 ms (p90 reported).
import AVFoundation
import SpikeKit
import VideoToolbox

func makeProxy(from src: URL, to dst: URL) async throws -> (seconds: Double, frames: Int) {
    try? FileManager.default.removeItem(at: dst)
    let asset = AVURLAsset(url: src)
    let track = try await asset.loadTracks(withMediaType: .video)[0]
    let fps = try await track.load(.nominalFrameRate)
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
    out.alwaysCopiesSampleData = false
    reader.add(out)
    let writer = try AVAssetWriter(outputURL: dst, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: 1280, AVVideoHeightKey: 720,
        AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
        AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true],
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: 4_000_000,
            AVVideoMaxKeyFrameIntervalKey: Int((fps / 2).rounded()),     // keyframe every 0.5 s → cheap seeks
            AVVideoAllowFrameReorderingKey: false,                       // no B-frames → cheaper decode while scrubbing
            kVTCompressionPropertyKey_RealTime as String: false,
        ]])
    input.expectsMediaDataInRealTime = false
    writer.add(input)
    guard reader.startReading(), writer.startWriting() else { throw reader.error ?? writer.error! }
    writer.startSession(atSourceTime: .zero)
    let start = ContinuousClock.now
    let counter = Unchecked(Counter())
    let io = Unchecked((input, out as AVAssetReaderOutput))
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        let q = DispatchQueue(label: "proxy")
        io.value.0.requestMediaDataWhenReady(on: q) {
            while io.value.0.isReadyForMoreMediaData {
                guard let sb = io.value.1.copyNextSampleBuffer() else { io.value.0.markAsFinished(); cont.resume(); return }
                io.value.0.append(sb)
                counter.value.n += 1
                if counter.value.n % 18_000 == 0 { print("    … \(counter.value.n / Int(fps) / 60) min done") }
            }
        }
    }
    await writer.finishWriting()
    if writer.status == .failed { throw writer.error! }
    return ((ContinuousClock.now - start).seconds, counter.value.n)
}
final class Counter { var n = 0 }

@MainActor
func seekLatencies(_ url: URL, times: [CMTime]) async throws -> [Double] {
    let item = AVPlayerItem(asset: AVURLAsset(url: url))
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    item.add(output)
    let player = AVPlayer(playerItem: item)
    try await Frames.waitReady(item)
    var lat: [Double] = []
    for t in times {
        let t0 = ContinuousClock.now
        await player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        while ContinuousClock.now - t0 < .seconds(3) {
            if output.hasNewPixelBuffer(forItemTime: t), output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) != nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        lat.append((ContinuousClock.now - t0).seconds * 1000)
    }
    _ = player
    return lat
}

func pct(_ v: [Double], _ p: Double) -> Double { let s = v.sorted(); return s[min(s.count - 1, Int(p * Double(s.count)))] }

@MainActor
func run() async throws {
    print("S5 — long media")
    let fixtures = try FileManager.default.contentsOfDirectory(atPath: Spike.root.appendingPathComponent("Fixtures").path)
    guard let name = fixtures.first(where: { $0.hasPrefix("long_") }) else { fatalError("run scripts/make-fixtures.sh") }
    let src = Spike.fixture(name)
    let duration = try await AVURLAsset(url: src).load(.duration).seconds
    let proxy = Spike.out("s5").appendingPathComponent("proxy_720p.mov")
    print(String(format: "  source: %@ (%.0f min)", name, duration / 60))

    let (secs, frames) = try await makeProxy(from: src, to: proxy)
    let speed = duration / secs
    let srcSize = (try FileManager.default.attributesOfItem(atPath: src.path)[.size] as! Int)
    let pxSize = (try FileManager.default.attributesOfItem(atPath: proxy.path)[.size] as! Int)
    print(String(format: "  proxy: %d frames in %.1fs → %.1f× realtime (%.0f fps); %.2f GB → %.2f GB (%.1f GB/h)",
                 frames, secs, speed, Double(frames) / secs, Double(srcSize) / 1e9, Double(pxSize) / 1e9, Double(pxSize) / 1e9 / (duration / 3600)))

    var rng = SystemRandomNumberGenerator()
    let times = (0..<40).map { _ in CMTime(value: CMTimeValue(Int.random(in: 60...(Int(duration) - 5) * 60, using: &rng)), timescale: 60) }
    let orig = try await seekLatencies(src, times: times)
    let prox = try await seekLatencies(proxy, times: times)
    print(String(format: "  seek original: median %.0f ms · p90 %.0f ms · max %.0f ms", pct(orig, 0.5), pct(orig, 0.9), orig.max()!))
    print(String(format: "  seek proxy:    median %.0f ms · p90 %.0f ms · max %.0f ms", pct(prox, 0.5), pct(prox, 0.9), prox.max()!))

    Spike.verdict("S5 proxy speed", speed >= 15, String(format: "%.1f× realtime (target ≥ 15×)", speed))
    Spike.verdict("S5 proxy seek", pct(prox, 0.5) < 100, String(format: "median %.0f ms, p90 %.0f ms (target median < 100 ms)", pct(prox, 0.5), pct(prox, 0.9)))
    Spike.writeResult("s5", ["sourceMinutes": duration / 60, "proxySeconds": secs, "proxyXRealtime": speed,
                             "proxyGBperHour": Double(pxSize) / 1e9 / (duration / 3600),
                             "seekOrigMedianMs": pct(orig, 0.5), "seekOrigP90Ms": pct(orig, 0.9),
                             "seekProxyMedianMs": pct(prox, 0.5), "seekProxyP90Ms": pct(prox, 0.9)])
}

try await run()
