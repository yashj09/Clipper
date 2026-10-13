import Foundation

public enum VideoCodec: String, Codable, Sendable, CaseIterable {
    case h264, hevc, hevcAlpha, prores422, prores422HQ, prores4444

    public var supportsAlpha: Bool { self == .hevcAlpha || self == .prores4444 }
    public var isProRes: Bool { rawValue.hasPrefix("prores") }
}

public enum ContainerFormat: String, Codable, Sendable { case mp4, mov
    public var fileExtension: String { rawValue }
}

/// Subtitle files written next to an export. `ass` keeps the caption styling (font, colours, outline, position)
/// and karaoke word timing; `srt`/`vtt` are plain text.
public enum SidecarFormat: String, Codable, Sendable, CaseIterable { case srt, vtt, ass
    public var fileExtension: String { rawValue }
}

/// How to render a timeline to a file. Platform presets bake in each platform's sweet spot.
public struct ExportPreset: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// Output size; nil = the timeline's canvas.
    public var width: Int?
    public var height: Int?
    public var codec: VideoCodec
    public var container: ContainerFormat
    /// Average video bitrate in Mb/s (ignored by ProRes).
    public var videoBitrate: Double?
    public var audioBitrate: Int
    /// Integrated loudness target (LUFS); nil = leave levels as mixed.
    public var loudness: Double?
    public var truePeak: Double
    public var transparentBackground: Bool
    public var sidecars: [SidecarFormat]

    public init(id: String, name: String, width: Int? = nil, height: Int? = nil, codec: VideoCodec, container: ContainerFormat,
                videoBitrate: Double? = nil, audioBitrate: Int = 192_000, loudness: Double? = -14, truePeak: Double = -1,
                transparentBackground: Bool = false, sidecars: [SidecarFormat] = [.srt]) {
        self.id = id; self.name = name; self.width = width; self.height = height; self.codec = codec; self.container = container
        self.videoBitrate = videoBitrate; self.audioBitrate = audioBitrate; self.loudness = loudness; self.truePeak = truePeak
        self.transparentBackground = transparentBackground; self.sidecars = sidecars
    }

    public static let builtIn: [ExportPreset] = [
        ExportPreset(id: "shorts-1080x1920", name: "Shorts / Reels / TikTok (1080×1920, H.264)", width: 1080, height: 1920,
                     codec: .h264, container: .mp4, videoBitrate: 16),
        ExportPreset(id: "youtube-1080p", name: "YouTube 1080p (H.264)", width: 1920, height: 1080,
                     codec: .h264, container: .mp4, videoBitrate: 16),
        ExportPreset(id: "youtube-4k", name: "YouTube 4K (HEVC)", width: 3840, height: 2160,
                     codec: .hevc, container: .mp4, videoBitrate: 45),
        ExportPreset(id: "square-1080", name: "Square 1080 (H.264)", width: 1080, height: 1080,
                     codec: .h264, container: .mp4, videoBitrate: 12),
        ExportPreset(id: "portrait-4x5", name: "Feed 4:5 (1080×1350, H.264)", width: 1080, height: 1350,
                     codec: .h264, container: .mp4, videoBitrate: 12),
        ExportPreset(id: "master-hevc", name: "Master HEVC (timeline size)", codec: .hevc, container: .mov, videoBitrate: 60,
                     loudness: nil, sidecars: [.srt, .vtt, .ass]),
        ExportPreset(id: "master-prores422hq", name: "Master ProRes 422 HQ", codec: .prores422HQ, container: .mov,
                     loudness: nil, sidecars: [.srt, .vtt, .ass]),
        ExportPreset(id: "overlay-prores4444", name: "Transparent overlay (ProRes 4444)", codec: .prores4444, container: .mov,
                     loudness: nil, transparentBackground: true, sidecars: []),
        ExportPreset(id: "overlay-hevc-alpha", name: "Transparent overlay (HEVC + alpha)", codec: .hevcAlpha, container: .mov,
                     videoBitrate: 20, loudness: nil, transparentBackground: true, sidecars: []),
    ]

    public static func named(_ id: String) -> ExportPreset? { builtIn.first { $0.id == id } }

    /// The preset with the user's export settings applied (no caption sidecars when they're turned off).
    public func applying(_ settings: ClipperSettings.Export) -> ExportPreset {
        var p = self
        if !settings.writeSidecars { p.sidecars = [] }
        return p
    }

    /// False when the preset has a fixed size whose aspect ratio differs from the canvas (the export is letterboxed).
    public func matchesAspect(of canvas: Canvas) -> Bool {
        guard let width, let height, width > 0, height > 0, canvas.height > 0 else { return true }
        return abs(Double(width) / Double(height) - canvas.aspect) <= 0.01 * canvas.aspect
    }
}
