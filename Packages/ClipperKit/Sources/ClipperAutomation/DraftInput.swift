import ClipperCore
import Foundation

/// One source clip offered to the draft, with whatever analysis exists for it.
public struct ClipInput: Sendable {
    public var asset: MediaAsset
    public var analysis: AssetAnalysis
    /// Template slot to fill; nil = the primary slot.
    public var slot: String?
    /// Optional user trim of the source, in seconds.
    public var inPoint: Double?
    public var outPoint: Double?

    public init(asset: MediaAsset, analysis: AssetAnalysis = AssetAnalysis(), slot: String? = nil,
                inPoint: Double? = nil, outPoint: Double? = nil) {
        self.asset = asset; self.analysis = analysis; self.slot = slot; self.inPoint = inPoint; self.outPoint = outPoint
    }

    var range: ClosedRange<Double> {
        let d = asset.info.duration.seconds
        let a = max(0, min(inPoint ?? 0, d)), b = max(a, min(outPoint ?? d, d))
        return a...b
    }
}

public struct DraftSettings: Sendable {
    /// Replaces `{title}` in template elements; elements needing a title are skipped when nil.
    public var title: String?
    public var seed: UInt64
    /// Overrides the template (nil = template default).
    public var captions: Bool?
    public var music: Bool?
    public var maxDuration: Double?
    /// Force a specific music track.
    public var musicID: String?
    public var name: String

    public init(title: String? = nil, seed: UInt64 = 1, captions: Bool? = nil, music: Bool? = nil,
                maxDuration: Double? = nil, musicID: String? = nil, name: String = "Draft") {
        self.title = title; self.seed = seed; self.captions = captions; self.music = music
        self.maxDuration = maxDuration; self.musicID = musicID; self.name = name
    }
}

public struct DraftInput: Sendable {
    public var template: Template
    public var clips: [ClipInput]
    /// Candidate music (user library + bundled), with analysis where available.
    public var music: [MusicTrack]
    public var settings: DraftSettings

    public init(template: Template, clips: [ClipInput], music: [MusicTrack] = [], settings: DraftSettings = DraftSettings()) {
        self.template = template; self.clips = clips; self.music = music; self.settings = settings
    }
}

extension DraftInput {
    /// What to store in the timeline's provenance so the draft can be re-run (`Redraft`).
    var record: DraftRecord {
        DraftRecord(clips: clips.map { DraftRecord.Clip(asset: $0.asset.id, slot: $0.slot, inPoint: $0.inPoint, outPoint: $0.outPoint) },
                    title: settings.title, captions: settings.captions, music: settings.music,
                    maxDuration: settings.maxDuration, musicID: settings.musicID)
    }
}

/// Human-readable account of what the draft did, shown in the app and CLI.
public struct DraftReport: Sendable, Equatable {
    public var notes: [String] = []
    public var warnings: [String] = []
    public var removedSeconds: Double = 0
    /// Stutters and abandoned sentence starts cut by the speech edits.
    public var removedRestarts: Int = 0
    public var musicTrack: String?
    public init() {}

    var speechEditNote: String? {
        let parts = [(removedRestarts, "false start")].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
        return parts.isEmpty ? nil : "Removed " + parts.joined(separator: " and ")
    }
}

public struct DraftResult: Sendable {
    public var timeline: Timeline
    public var report: DraftReport
    /// Assets the timeline references that weren't inputs (the chosen music); register them before rendering.
    public var addedAssets: [MediaAsset]
}

/// Stable 64-bit FNV-1a (Swift's `hashValue` is randomized per process; drafts must be reproducible).
func stableHash(_ s: String) -> UInt64 {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100_0000_01b3 }
    return h
}

extension RationalTime {
    /// Seconds → time snapped to the canvas frame grid (edits are frame-accurate).
    static func frames(_ seconds: Double, _ rate: FrameRate) -> RationalTime {
        RationalTime(seconds: Swift.max(seconds, 0)).roundedToFrame(rate)
    }
}
