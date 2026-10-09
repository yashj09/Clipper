import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Paths, timing and reporting helpers shared by the spikes.
public enum Spike {
    /// Repository root, found by walking up from the current directory to the folder that contains `Fixtures/`.
    public static let root: URL = {
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Fixtures").path) { return dir }
            dir.deleteLastPathComponent()
        }
        fatalError("Run from inside the Clipper repo (Fixtures/ not found)")
    }()

    public static func fixture(_ name: String) -> URL { root.appendingPathComponent("Fixtures/\(name)") }

    public static func out(_ spike: String) -> URL {
        let dir = root.appendingPathComponent("Spikes/out/\(spike)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    public static func time<T>(_ label: String, isolation: isolated (any Actor)? = #isolation,
                               _ body: () async throws -> T) async rethrows -> (T, Double) {
        let start = ContinuousClock.now
        let value = try await body()
        let secs = (ContinuousClock.now - start).seconds
        print(String(format: "  ⏱  %@: %.3fs", label, secs))
        return (value, secs)
    }

    /// Writes a machine-readable result next to the spike's other outputs.
    public static func writeResult(_ spike: String, _ result: [String: Any]) {
        let url = out(spike).appendingPathComponent("result.json")
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
            print("  📄 \(url.path)")
        }
    }

    public static func verdict(_ name: String, _ pass: Bool, _ detail: String) {
        print("\(pass ? "✅ PASS" : "❌ FAIL")  \(name) — \(detail)")
    }
}

extension Duration {
    public var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

// MARK: - Pixel buffer utilities

public enum Pixels {
    /// PSNR over RGB for two same-sized 32BGRA buffers. Returns +inf when identical.
    public static func psnr(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Double {
        precondition(CVPixelBufferGetPixelFormatType(a) == kCVPixelFormatType_32BGRA)
        precondition(CVPixelBufferGetPixelFormatType(b) == kCVPixelFormatType_32BGRA)
        let w = CVPixelBufferGetWidth(a), h = CVPixelBufferGetHeight(a)
        guard w == CVPixelBufferGetWidth(b), h == CVPixelBufferGetHeight(b) else { return -1 }
        CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let pa = CVPixelBufferGetBaseAddress(a)!.assumingMemoryBound(to: UInt8.self)
        let pb = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
        let ra = CVPixelBufferGetBytesPerRow(a), rb = CVPixelBufferGetBytesPerRow(b)
        var sum: Double = 0
        for y in 0..<h {
            let rowA = pa + y * ra, rowB = pb + y * rb
            var rowSum = 0
            for x in 0..<w {
                for c in 0..<3 {
                    let d = Int(rowA[x * 4 + c]) - Int(rowB[x * 4 + c])
                    rowSum += d * d
                }
            }
            sum += Double(rowSum)
        }
        let mse = sum / Double(w * h * 3)
        return mse == 0 ? .infinity : 10 * log10(255 * 255 / mse)
    }

    /// Mean of each RGB channel in a 32BGRA buffer, normalised to 0…1. Used for coarse colour checks.
    public static func meanRGB(_ buf: CVPixelBuffer) -> SIMD3<Double> {
        CVPixelBufferLockBaseAddress(buf, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf), r = CVPixelBufferGetBytesPerRow(buf)
        let p = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        var acc = SIMD3<Double>(0, 0, 0)
        for y in stride(from: 0, to: h, by: 2) {
            for x in stride(from: 0, to: w, by: 2) {
                let o = y * r + x * 4
                acc += SIMD3(Double(p[o + 2]), Double(p[o + 1]), Double(p[o]))
            }
        }
        return acc / Double(((h + 1) / 2) * ((w + 1) / 2)) / 255
    }

    public static func savePNG(_ buf: CVPixelBuffer, to url: URL) {
        let ci = CIImage(cvPixelBuffer: buf)
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(ci, from: ci.extent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }

    public static func describeColor(_ buf: CVPixelBuffer) -> String {
        let prim = CVBufferCopyAttachment(buf, kCVImageBufferColorPrimariesKey, nil) as? String ?? "-"
        let trc = CVBufferCopyAttachment(buf, kCVImageBufferTransferFunctionKey, nil) as? String ?? "-"
        let fmt = CVPixelBufferGetPixelFormatType(buf)
        let fourcc = String(bytes: [24, 16, 8, 0].map { UInt8((fmt >> $0) & 0xff) }, encoding: .ascii) ?? "\(fmt)"
        return "fmt=\(fourcc) primaries=\(prim) transfer=\(trc)"
    }
}

// MARK: - Frame readers

/// Wraps non-Sendable AVFoundation references that we hand across isolation boundaries deliberately.
public struct Unchecked<T>: @unchecked Sendable { public let value: T; public init(_ v: T) { value = v } }

public enum Frames {
    nonisolated(unsafe) static let bgra: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]

    /// Decodes the frames whose presentation time is nearest each requested time (within half a frame).
    public static func decode(url: URL, at times: [CMTime]) async throws -> [CMTime: CVPixelBuffer] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [:] }
        let fps = try await track.load(.nominalFrameRate)
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: bgra)
        out.alwaysCopiesSampleData = false
        reader.add(out)
        reader.startReading()
        return collect(from: out, times: times, halfFrame: 0.5 / Double(max(fps, 1)))
    }

    static func collect(from out: AVAssetReaderOutput, times: [CMTime], halfFrame: Double) -> [CMTime: CVPixelBuffer] {
        var result: [CMTime: CVPixelBuffer] = [:]
        let wanted = times.sorted()
        var i = 0
        while i < wanted.count, let sb = out.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            while i < wanted.count, wanted[i].seconds < pts - halfFrame { i += 1 }   // skipped (should not happen)
            if i < wanted.count, abs(wanted[i].seconds - pts) <= halfFrame, let px = sb.imageBuffer {
                result[wanted[i]] = px
                i += 1
            }
        }
        return result
    }

    /// Pulls frames through the real *preview* path: AVPlayer + AVPlayerItemVideoOutput, seeking with zero tolerance.
    @MainActor
    public static func viaPlayer(item: AVPlayerItem, at times: [CMTime]) async throws -> [CMTime: CVPixelBuffer] {
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: bgra)
        item.add(output)
        let player = AVPlayer(playerItem: item)
        try await waitReady(item)
        var result: [CMTime: CVPixelBuffer] = [:]
        for t in times {
            await player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
            let deadline = ContinuousClock.now + .seconds(3)
            while ContinuousClock.now < deadline {
                if output.hasNewPixelBuffer(forItemTime: t) || result.isEmpty {
                    var shown = CMTime.zero
                    if let px = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: &shown) {
                        result[t] = px
                        break
                    }
                }
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        _ = player   // keep alive until done
        return result
    }

    @MainActor
    public static func waitReady(_ item: AVPlayerItem) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while item.status != .readyToPlay {
            if item.status == .failed { throw item.error ?? CocoaError(.featureUnsupported) }
            if ContinuousClock.now > deadline { throw CocoaError(.executableLoad) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
