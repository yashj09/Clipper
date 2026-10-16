import AVFoundation
import ClipperCore

/// A timeline resolved into AVFoundation objects, ready for AVPlayer (preview) or AVAssetReader (export).
public struct BuiltComposition: @unchecked Sendable {
    public let composition: AVComposition
    public let videoComposition: AVVideoComposition
    public let audioMix: AVAudioMix?
    public let duration: CMTime
    public let renderSize: CGSize

    /// A player item wired to the Clipper compositor. Pitch is preserved for speed-changed clips.
    @MainActor public func makePlayerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        item.audioMix = audioMix
        item.audioTimePitchAlgorithm = .spectral
        return item
    }
}

public struct BuildOptions: Sendable {
    /// Render below canvas resolution (e.g. 0.5 for a lighter preview). Layout is resolution-independent.
    public var renderScale: Double
    public var useProxies: Bool
    /// Transparent background (alpha exports); otherwise the canvas is cleared to black.
    public var transparent: Bool
    /// Output size override (export presets); nil = canvas × renderScale.
    public var outputSize: CGSize?

    public init(renderScale: Double = 1, useProxies: Bool = false, transparent: Bool = false, outputSize: CGSize? = nil) {
        self.renderScale = renderScale; self.useProxies = useProxies; self.transparent = transparent; self.outputSize = outputSize
    }
    public static let export = BuildOptions()
    public static let preview = BuildOptions(useProxies: true)
}

public enum BuildError: Error, CustomStringConvertible {
    case missingAsset(AssetID)
    case noTrack(String)
    public var description: String {
        switch self {
        case .missingAsset(let id): "Timeline references a missing asset (\(id))"
        case .noTrack(let why): why
        }
    }
}

/// Turns a `Timeline` into a composition + video composition (our compositor) + audio mix.
public enum CompositionBuilder {
    public static func build(_ timeline: Timeline, assets: [AssetID: MediaAsset], options: BuildOptions = .export) async throws -> BuiltComposition {
        let comp = AVMutableComposition()
        let duration = max(timeline.duration, timeline.canvas.frameRate.frameDuration).cmTime
        let loader = AssetLoader()

        // A blank base track spanning the whole timeline guarantees the compositor runs for every frame, even where
        // only text/solids are visible or nothing is (the composition's duration is defined by its tracks).
        let blank = try await BlankVideo.shared.asset()
        let base = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let blankTrack = try await blank.loadTracks(withMediaType: .video)[0]
        let oneSecond = CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1))
        try base.insertTimeRange(oneSecond, of: blankTrack, at: .zero)
        base.scaleTimeRange(oneSecond, toDuration: duration)

        var videoTrackOf: [ItemID: CMPersistentTrackID] = [:]
        /// Composition track holding the outgoing clip's tail for the transition into an item (keyed by the incoming item).
        var tailTrackOf: [ItemID: CMPersistentTrackID] = [:]
        var audioParams: [AVMutableAudioMixInputParameters] = []

        func sourceURL(_ asset: MediaAsset) -> URL {
            // A proxy whose file has gone (deleted, library moved) falls back to the original.
            let proxy = options.useProxies ? asset.proxyURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } : nil
            return proxy ?? asset.renderURL
        }

        for track in timeline.tracks {
            // Video segments (one composition track per model track: items never overlap within a track); transition
            // tails go on a second track per model track, since they overlap the incoming item.
            var compVideo: AVMutableCompositionTrack?, compAudio: AVMutableCompositionTrack?
            var tailVideo: AVMutableCompositionTrack?, tailAudio: AVMutableCompositionTrack?
            var volume = VolumeAutomation(), tailVolume = VolumeAutomation()
            let items = track.items.filter(\.enabled)
            for (index, item) in items.enumerated() {
                let incoming = Transitions.resolve(item, after: index > 0 ? items[index - 1] : nil, rate: timeline.canvas.frameRate)
                let at = item.start.cmTime

                // The outgoing clip keeps playing under the incoming item for the transition — whatever the incoming item
                // is (a clip, a still, a freeze frame, a title).
                if let incoming, let previous = incoming.outgoing, case .media(let prevRef) = previous.content,
                   let prevAsset = assets[prevRef.asset] {
                    let prevSrc = try await loader.tracks(sourceURL(prevAsset))
                    let tail = Transitions.tailSource(prevRef, assetDuration: prevAsset.info.duration, frameRate: prevAsset.info.frameRate,
                                                      length: incoming.duration)
                    let d = incoming.duration.cmTime
                    if track.kind.isVisual, !track.hidden, prevAsset.info.hasVideo, let v = prevSrc.video {
                        if tailVideo == nil { tailVideo = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) }
                        try tailVideo!.insertTimeRange(tail.range.cmTimeRange, of: v, at: at)
                        if tail.range.duration.cmTime != d { tailVideo!.scaleTimeRange(CMTimeRange(start: at, duration: tail.range.duration.cmTime), toDuration: d) }
                        tailTrackOf[item.id] = tailVideo!.trackID
                    }
                    // Audio crossfade, only from real media (a held last frame has no sound to continue).
                    if !tail.isHold, track.kind.hasAudio, prevRef.useAudio, !track.muted, let a = prevSrc.audio {
                        if tailAudio == nil { tailAudio = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
                        try tailAudio!.insertTimeRange(tail.range.cmTimeRange, of: a, at: at)
                        if tail.range.duration.cmTime != d { tailAudio!.scaleTimeRange(CMTimeRange(start: at, duration: tail.range.duration.cmTime), toDuration: d) }
                        let g = previous.gain.value(at: previous.range.duration) + track.gain
                        tailVolume.ramp(CMTimeRange(start: at, duration: d), from: Float(pow(10, g / 20)), to: 0)
                    }
                }

                guard case .media(let ref) = item.content else { continue }
                guard let asset = assets[ref.asset] else { throw BuildError.missingAsset(ref.asset) }
                let src = try await loader.tracks(sourceURL(asset))
                let sourceRange = ref.source.cmTimeRange
                let placed = item.range.duration.cmTime
                // The item's audio fades in over its transition.
                var heard = item
                if let incoming { heard.fadeIn = .max(item.fadeIn, incoming.duration) }

                if track.kind.isVisual, !track.hidden, asset.info.hasVideo, let v = src.video {
                    if compVideo == nil { compVideo = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) }
                    try compVideo!.insertTimeRange(sourceRange, of: v, at: at)
                    if ref.speed != 1 { compVideo!.scaleTimeRange(CMTimeRange(start: at, duration: sourceRange.duration), toDuration: placed) }
                    videoTrackOf[item.id] = compVideo!.trackID
                }
                if track.kind.hasAudio, ref.useAudio, !track.muted, let a = src.audio {
                    if compAudio == nil { compAudio = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
                    try compAudio!.insertTimeRange(sourceRange, of: a, at: at)
                    if ref.speed != 1 { compAudio!.scaleTimeRange(CMTimeRange(start: at, duration: sourceRange.duration), toDuration: placed) }
                    volume.add(item: heard, trackGain: track.gain)
                }
            }
            for (compTrack, automation) in [(compAudio, volume), (tailAudio, tailVolume)] {
                guard let compTrack else { continue }
                let p = AVMutableAudioMixInputParameters(track: compTrack)
                p.audioTimePitchAlgorithm = .spectral
                automation.apply(to: p)
                audioParams.append(p)
            }
        }

        let context = RenderContext(canvas: timeline.canvas, styles: timeline.styles,
                                    background: options.transparent ? .clear : .black)
        let instructions = makeInstructions(timeline, assets: assets, videoTrackOf: videoTrackOf, tailTrackOf: tailTrackOf,
                                            duration: duration, context: context)
        let size = options.outputSize ?? CGSize(width: evenRound(Double(timeline.canvas.width) * options.renderScale),
                                                height: evenRound(Double(timeline.canvas.height) * options.renderScale))
        let config = AVVideoComposition.Configuration(
            colorPrimaries: AVVideoColorPrimaries_ITU_R_709_2,
            colorTransferFunction: AVVideoTransferFunction_ITU_R_709_2,
            colorYCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_709_2,
            customVideoCompositorClass: ClipperCompositor.self,
            frameDuration: timeline.canvas.frameRate.cmFrameDuration,
            instructions: instructions,
            renderSize: size)
        let videoComposition = AVVideoComposition(configuration: config)
        var mix: AVAudioMix?
        if !audioParams.isEmpty {
            let m = AVMutableAudioMix()
            m.inputParameters = audioParams
            mix = m
        }
        return BuiltComposition(composition: comp, videoComposition: videoComposition, audioMix: mix, duration: duration, renderSize: size)
    }

    /// Splits the timeline wherever the set of visible items changes; each span gets the layers active in it.
    static func makeInstructions(_ timeline: Timeline, assets: [AssetID: MediaAsset], videoTrackOf: [ItemID: CMPersistentTrackID],
                                 tailTrackOf: [ItemID: CMPersistentTrackID] = [:],
                                 duration: CMTime, context: RenderContext) -> [RenderInstruction] {
        let visual = timeline.tracks.filter { $0.kind.isVisual && !$0.hidden }
        let rate = timeline.canvas.frameRate
        // Each track's enabled items and the transition into each of them.
        let lanes: [(items: [Item], incoming: [ItemID: Transitions.Resolved])] = visual.map { track in
            let items = track.items.filter(\.enabled)
            var incoming: [ItemID: Transitions.Resolved] = [:]
            for (i, item) in items.enumerated() {
                incoming[item.id] = Transitions.resolve(item, after: i > 0 ? items[i - 1] : nil, rate: rate)
            }
            return (items, incoming)
        }
        var cuts = Set<RationalTime>([.zero, RationalTime(duration)])
        for lane in lanes {
            for i in lane.items {
                cuts.insert(i.start); cuts.insert(i.end)
                if let t = lane.incoming[i.id] { cuts.insert(i.start + t.duration) }
            }
        }
        let end = RationalTime(duration)
        let bounds = cuts.filter { $0 <= end }.sorted()
        let tiny = RationalTime(value: 1, scale: 1_000_000)
        var out: [RenderInstruction] = []
        for (a, b) in zip(bounds, bounds.dropFirst()) where a < b {
            let mid = a + tiny
            var layers: [RenderLayer] = []
            for lane in lanes {
                guard let item = lane.items.first(where: { $0.range.contains(mid) }),
                      var layer = renderLayer(item, assets: assets, videoTrackOf: videoTrackOf) else { continue }
                guard let t = lane.incoming[item.id], mid < item.start + t.duration else { layers.append(layer); continue }
                // Inside the transition into `item`: the outgoing clip's tail below, the item, and the dip colour on top.
                let s = item.start.seconds, d = t.duration.seconds, half = s + d / 2
                // A media tail plays from its own composition track; text, stills and solids just stay up longer.
                if let previous = t.outgoing,
                   var tail = renderLayer(previous, assets: assets, videoTrackOf: tailTrackOf[item.id].map { [previous.id: $0] } ?? [:]) {
                    tail.duration = previous.range.duration + t.duration
                    tail.fadeOut = .zero
                    if t.kind != .crossDissolve { tail.envelope = [.init(half - 1e-6, 1), .init(half, 0)] }
                    layers.append(tail)
                }
                layer.envelope = t.kind == .crossDissolve ? [.init(s, 0), .init(s + d, 1)]
                    : (t.outgoing == nil ? [] : [.init(half - 1e-6, 0), .init(half, 1)])
                layers.append(layer)
                if t.kind != .crossDissolve {
                    var dip = RenderLayer(itemID: item.id, source: .solid(t.kind == .dipToWhite ? .white : .black), transform: .fullFrame,
                                          opacity: .constant(1), start: item.start, duration: t.duration, fadeIn: .zero, fadeOut: .zero)
                    dip.envelope = t.outgoing == nil ? [.init(s, 1), .init(s + d, 0)] : [.init(s, 0), .init(half, 1), .init(s + d, 0)]
                    layers.append(dip)
                }
            }
            out.append(RenderInstruction(timeRange: CMTimeRange(start: a.cmTime, end: b.cmTime), layers: layers, context: context))
        }
        return out
    }

    static func renderLayer(_ item: Item, assets: [AssetID: MediaAsset], videoTrackOf: [ItemID: CMPersistentTrackID]) -> RenderLayer? {
        let source: RenderLayer.Source
        switch item.content {
        case .media(let ref):
            guard let asset = assets[ref.asset], let trackID = videoTrackOf[item.id] else { return nil }
            let info = asset.info
            source = .media(trackID: trackID, displaySize: SIMD2(Double(info.displayWidth), Double(info.displayHeight)),
                            orientation: Orientation(rotation: info.rotation, mirrored: info.mirrored), transfer: info.transfer)
        case .image(let id):
            guard let asset = assets[id] else { return nil }
            source = .image(asset.renderURL, displaySize: SIMD2(Double(asset.info.displayWidth), Double(asset.info.displayHeight)))
        case .text(let t): source = .text(t)
        case .caption(let c): source = .caption(c)
        case .solid(let c): source = .solid(c)
        }
        var layer = RenderLayer(itemID: item.id, source: source, transform: item.transform, opacity: item.opacity,
                                start: item.start, duration: item.range.duration, fadeIn: item.fadeIn, fadeOut: item.fadeOut)
        layer.color = item.color
        layer.blend = item.blend
        return layer
    }

    static func evenRound(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }
}

/// Resolving transitions: how long each really is, and what it comes from.
enum Transitions {
    struct Resolved {
        var kind: Transition.Kind
        /// Clamped to the incoming item (and the outgoing one, when there is one), at least a frame.
        var duration: RationalTime
        /// The item right before on the same track (touching within half a frame); nil = the transition comes from
        /// whatever is below (a fade from the background).
        var outgoing: Item?
    }

    static func resolve(_ item: Item, after previous: Item?, rate: FrameRate) -> Resolved? {
        guard let t = item.transition, t.duration > .zero else { return nil }
        let half = rate.frameDuration.seconds / 2
        let touching = previous.flatMap { abs(($0.end - item.start).seconds) <= half ? $0 : nil }
        var d = RationalTime.min(t.duration, item.range.duration)
        if let touching { d = .min(d, touching.range.duration) }
        d = .max(d.roundedToFrame(rate), rate.frameDuration)
        return Resolved(kind: t.kind, duration: d, outgoing: touching)
    }

    /// The source to play past the outgoing clip's out-point: the media that follows it when the file has enough,
    /// otherwise its last frame held (`isHold`).
    static func tailSource(_ ref: MediaRef, assetDuration: RationalTime, frameRate: Double, length: RationalTime)
        -> (range: TimeRange, isHold: Bool) {
        let needed = length.timesSpeed(ref.speed)
        if ref.source.end + needed <= assetDuration { return (TimeRange(start: ref.source.end, duration: needed), false) }
        let frame = RationalTime(seconds: 1 / max(frameRate, 1))
        let start = RationalTime.max(.zero, RationalTime.min(ref.source.end, assetDuration) - frame)
        return (TimeRange(start: start, duration: frame), true)
    }
}

/// Loads each source file's tracks once per build. Keeps the `AVURLAsset`s alive: an `AVAssetTrack` only holds a
/// weak reference to its asset, and inserting a track whose asset was freed fails with -11800/-12780.
final class AssetLoader: @unchecked Sendable {
    struct Tracks { var asset: AVURLAsset; var video: AVAssetTrack?; var audio: AVAssetTrack? }
    private var cache: [URL: Tracks] = [:]

    func tracks(_ url: URL) async throws -> Tracks {
        if let hit = cache[url] { return hit }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let t = Tracks(asset: asset, video: try await asset.loadTracks(withMediaType: .video).first,
                       audio: try await asset.loadTracks(withMediaType: .audio).first)
        cache[url] = t
        return t
    }
}

/// Converts item gain keyframes (dB), fades and track gain into AVAudioMix linear volume ramps.
struct VolumeAutomation {
    private var ramps: [(CMTimeRange, Float, Float)] = []

    mutating func add(item: Item, trackGain: Double) {
        let start = item.start, dur = item.range.duration
        // Breakpoints: item edges, gain keyframes, fade ends; eased segments are subdivided into linear pieces.
        var points = Set<RationalTime>([.zero, dur])
        for k in item.gain.keys where k.time > .zero && k.time < dur { points.insert(k.time) }
        if item.fadeIn > .zero, item.fadeIn < dur { points.insert(item.fadeIn) }
        if item.fadeOut > .zero, item.fadeOut < dur { points.insert(dur - item.fadeOut) }
        let sorted = points.sorted()
        var fine: [RationalTime] = []
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            let pieces = item.gain.isAnimated ? 6 : 1
            for i in 0..<pieces { fine.append(a + (b - a) * (Double(i) / Double(pieces))) }
        }
        fine.append(dur)
        func linear(_ t: RationalTime) -> Float {
            var g = item.gain.value(at: t) + trackGain
            var f = 1.0
            if item.fadeIn > .zero { f *= min(max(t.seconds / item.fadeIn.seconds, 0), 1) }
            if item.fadeOut > .zero { f *= min(max((dur - t).seconds / item.fadeOut.seconds, 0), 1) }
            if g < -90 { g = -200 }
            return Float(pow(10, g / 20) * f)
        }
        for (a, b) in zip(fine, fine.dropFirst()) where a < b {
            ramps.append((CMTimeRange(start: (start + a).cmTime, end: (start + b).cmTime), linear(a), linear(b)))
        }
    }

    mutating func ramp(_ range: CMTimeRange, from v0: Float, to v1: Float) { ramps.append((range, v0, v1)) }

    func apply(to p: AVMutableAudioMixInputParameters) {
        for (range, v0, v1) in ramps {
            if v0 == v1 { p.setVolume(v0, at: range.start) } else { p.setVolumeRamp(fromStartVolume: v0, toEndVolume: v1, timeRange: range) }
        }
    }
}

/// A one-frame black clip generated on first use, stretched under every composition as its timing backbone.
actor BlankVideo {
    static let shared = BlankVideo()
    private var cached: AVURLAsset?

    func asset() async throws -> AVURLAsset {
        if let cached { return cached }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Clipper", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("blank-v1.mov")
        if !FileManager.default.fileExists(atPath: url.path) { try await write(url) }
        let a = AVURLAsset(url: url)
        cached = a
        return a
    }

    private func write(_ url: URL) async throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".mov")
        let writer = try AVAssetWriter(outputURL: tmp, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 16, AVVideoHeightKey: 16])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        memset(CVPixelBufferGetBaseAddress(pb!), 0, CVPixelBufferGetDataSize(pb!))
        CVPixelBufferUnlockBaseAddress(pb!, [])
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        adaptor.append(pb!, withPresentationTime: .zero)
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
    }
}
