import Foundation

/// Transfer function of a video source.
public enum TransferFunction: String, Codable, Sendable { case sdr, hlg, pq }

public enum MediaKind: String, Codable, Sendable { case video, audio, image }

/// Facts about a media file, gathered once at import.
public struct MediaInfo: Codable, Sendable, Equatable {
    public var kind: MediaKind
    public var duration: RationalTime
    /// Coded pixel size, before rotation.
    public var naturalWidth: Int
    public var naturalHeight: Int
    /// Clockwise display rotation in degrees (0, 90, 180, 270), from the track's preferred transform.
    public var rotation: Int
    public var mirrored: Bool
    /// Nominal (average) frame rate; `isVFR` marks phone footage with variable timing.
    public var frameRate: Double
    public var isVFR: Bool
    public var transfer: TransferFunction
    public var hasAlpha: Bool
    public var videoCodec: String?
    public var audioChannels: Int
    public var audioSampleRate: Double
    public var creationDate: Date?

    public init(kind: MediaKind, duration: RationalTime, naturalWidth: Int = 0, naturalHeight: Int = 0, rotation: Int = 0,
                mirrored: Bool = false, frameRate: Double = 0, isVFR: Bool = false, transfer: TransferFunction = .sdr,
                hasAlpha: Bool = false, videoCodec: String? = nil, audioChannels: Int = 0, audioSampleRate: Double = 0,
                creationDate: Date? = nil) {
        self.kind = kind; self.duration = duration; self.naturalWidth = naturalWidth; self.naturalHeight = naturalHeight
        self.rotation = rotation; self.mirrored = mirrored; self.frameRate = frameRate; self.isVFR = isVFR
        self.transfer = transfer; self.hasAlpha = hasAlpha; self.videoCodec = videoCodec
        self.audioChannels = audioChannels; self.audioSampleRate = audioSampleRate; self.creationDate = creationDate
    }

    public var hasVideo: Bool { kind != .audio }
    public var hasAudio: Bool { audioChannels > 0 }
    /// Display size after rotation.
    public var displayWidth: Int { rotation % 180 == 0 ? naturalWidth : naturalHeight }
    public var displayHeight: Int { rotation % 180 == 0 ? naturalHeight : naturalWidth }
    public var displayAspect: Double { displayHeight > 0 ? Double(displayWidth) / Double(displayHeight) : 1 }
}

/// Content-derived identity: survives renames and moves, used to cache analysis.
public struct AssetKey: Codable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

public struct MediaAsset: Codable, Sendable, Equatable, Identifiable {
    public var id: AssetID
    public var key: AssetKey
    public var name: String
    /// Absolute file URL currently resolving to the media.
    public var url: URL
    public var info: MediaInfo
    /// A transcoded file used for playback when AVFoundation can't read the original (webm, mkv…).
    public var playableURL: URL?
    public var proxyURL: URL?
    public var tags: [String]

    public init(id: AssetID = UUID(), key: AssetKey, name: String, url: URL, info: MediaInfo,
                playableURL: URL? = nil, proxyURL: URL? = nil, tags: [String] = []) {
        self.id = id; self.key = key; self.name = name; self.url = url; self.info = info
        self.playableURL = playableURL; self.proxyURL = proxyURL; self.tags = tags
    }

    /// The file to render from at full quality.
    public var renderURL: URL { playableURL ?? url }
}

public enum MusicLicense: Codable, Sendable, Equatable {
    /// Requires the attribution text to be shown in credits / description.
    case ccBy(attribution: String)
    case cc0
    /// User's own or licensed track (no attribution generated).
    case owned
    case generated(model: String)

    public var attribution: String? { if case .ccBy(let a) = self { a } else { nil } }
}

/// A music track available to the music picker, with its analysis.
public struct MusicTrack: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var artist: String
    public var url: URL
    public var duration: Double
    public var license: MusicLicense
    public var moods: [String]
    public var genres: [String]
    public var bpm: Double?
    /// Average energy 0…1 (from analysis), used to match pacing.
    public var energy: Double?
    public var beats: BeatGrid?

    public init(id: String, title: String, artist: String, url: URL, duration: Double, license: MusicLicense,
                moods: [String] = [], genres: [String] = [], bpm: Double? = nil, energy: Double? = nil, beats: BeatGrid? = nil) {
        self.id = id; self.title = title; self.artist = artist; self.url = url; self.duration = duration
        self.license = license; self.moods = moods; self.genres = genres; self.bpm = bpm; self.energy = energy; self.beats = beats
    }
}
