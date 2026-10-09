import AVFoundation
import ClipperCore
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

public enum MediaError: Error, CustomStringConvertible {
    case unreadable(URL)
    case unsupported(URL, reason: String)
    case noVideo(URL)

    public var description: String {
        switch self {
        case .unreadable(let u): "Can't read \(u.lastPathComponent)"
        case .unsupported(let u, let r): "\(u.lastPathComponent) isn't playable by AVFoundation (\(r)); it needs transcoding"
        case .noVideo(let u): "\(u.lastPathComponent) has no video track"
        }
    }
}

/// Gathers `MediaInfo` and the content key for a file. Run once at import.
public enum MediaProbe {
    /// Default duration for still images placed on a timeline.
    public static let stillDuration = RationalTime(value: 5, scale: 1)

    public static func probe(_ url: URL) async throws -> MediaInfo {
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw MediaError.unreadable(url) }
        if let type = UTType(filenameExtension: url.pathExtension.lowercased()), type.conforms(to: .image) {
            return try probeImage(url)
        }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let (playable, duration) = try await asset.load(.isPlayable, .duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard playable || !videoTracks.isEmpty || !audioTracks.isEmpty else {
            throw MediaError.unsupported(url, reason: "no playable tracks")
        }
        var info = MediaInfo(kind: videoTracks.isEmpty ? .audio : .video, duration: RationalTime(duration))
        info.creationDate = try? await asset.load(.creationDate)?.load(.dateValue)

        if let v = videoTracks.first {
            let (size, transform, fps, minFrame, formats) = try await v.load(.naturalSize, .preferredTransform, .nominalFrameRate,
                                                                              .minFrameDuration, .formatDescriptions)
            info.naturalWidth = Int(abs(size.width).rounded())
            info.naturalHeight = Int(abs(size.height).rounded())
            (info.rotation, info.mirrored) = orientation(of: transform)
            info.frameRate = Double(fps)
            let nearest = FrameRate.nearestStandard(to: Double(fps))
            let minDur = minFrame.isNumeric ? minFrame.seconds : 0
            info.isVFR = abs(Double(fps) - nearest.fps) > 0.05 || (minDur > 0 && minDur < 0.9 / Double(max(fps, 1)))
            if let desc = formats.first {
                info.videoCodec = fourCC(CMFormatDescriptionGetMediaSubType(desc))
                info.transfer = transferFunction(desc)
                let alpha = CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_ContainsAlphaChannel)
                info.hasAlpha = (alpha as? Bool) ?? false
            }
        }
        if let a = audioTracks.first, let desc = try await a.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
            info.audioChannels = Int(asbd.mChannelsPerFrame)
            info.audioSampleRate = asbd.mSampleRate
        }
        return info
    }

    static func probeImage(_ url: URL) throws -> MediaInfo {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { throw MediaError.unreadable(url) }
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let exif = props[kCGImagePropertyOrientation] as? UInt32 ?? 1
        // EXIF orientations 5–8 swap axes; images are decoded upright by ImageIO so report display size.
        let swap = (5...8).contains(exif)
        return MediaInfo(kind: .image, duration: stillDuration, naturalWidth: swap ? h : w, naturalHeight: swap ? w : h,
                         hasAlpha: (props[kCGImagePropertyHasAlpha] as? Bool) ?? false)
    }

    /// Clockwise display rotation (0/90/180/270) and mirroring from a track's preferred transform.
    public static func orientation(of t: CGAffineTransform) -> (rotation: Int, mirrored: Bool) {
        let mirrored = (t.a * t.d - t.b * t.c) < 0
        var degrees = Int((atan2(t.b, t.a) * 180 / .pi).rounded())
        if mirrored { degrees = Int((atan2(-t.b, -t.a) * 180 / .pi).rounded()) }
        let normalized = ((degrees % 360) + 360) % 360
        let snapped = (Int((Double(normalized) / 90).rounded()) * 90) % 360
        return (snapped, mirrored)
    }

    static func transferFunction(_ desc: CMFormatDescription) -> TransferFunction {
        guard let tf = CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        else { return .sdr }
        if tf == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) { return .hlg }
        if tf == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) { return .pq }
        return .sdr
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "\(code)"
    }

    /// Content key: SHA-256 over size + first/middle/last 4 MB + duration. Fast even for multi-GB recordings,
    /// stable across renames/moves, and distinct for different edits of the "same" file.
    public static func assetKey(_ url: URL, duration: RationalTime) throws -> AssetKey {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        var hasher = SHA256()
        withUnsafeBytes(of: size.littleEndian) { hasher.update(bufferPointer: $0) }
        let chunk: UInt64 = 4 << 20
        for offset in Set([0, size > chunk ? size / 2 - chunk / 2 : 0, size > chunk ? size - chunk : 0]).sorted() {
            try handle.seek(toOffset: offset)
            if let data = try handle.read(upToCount: Int(chunk)) { hasher.update(data: data) }
        }
        hasher.update(data: Data(duration.reduced.description.utf8))
        return AssetKey(hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined())
    }

    /// Probes and keys a file in one go, producing a `MediaAsset` ready to store.
    public static func makeAsset(_ url: URL, id: AssetID = UUID()) async throws -> MediaAsset {
        let info = try await probe(url)
        let key = try assetKey(url, duration: info.duration)
        return MediaAsset(id: id, key: key, name: url.deletingPathExtension().lastPathComponent, url: url, info: info)
    }
}
