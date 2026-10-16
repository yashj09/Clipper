import AVFoundation
import ClipperCore
import simd

/// Everything the compositor needs that is constant for a whole composition.
public struct RenderContext: Sendable {
    public var canvas: Canvas
    public var styles: [String: TextStyle]
    public var background: RGBA
    /// Stable per-style fingerprints for the text texture cache (computed once, not per frame).
    let styleHashes: [String: Int]
    public init(canvas: Canvas, styles: [String: TextStyle], background: RGBA = .black) {
        self.canvas = canvas; self.styles = styles; self.background = background
        styleHashes = styles.mapValues { (try? ClipperJSON.encode($0)).map { $0.hashValue } ?? 0 }
    }
}

/// One visual layer active during an instruction's time range (a timeline item, resolved for rendering).
public struct RenderLayer: Sendable {
    public enum Source: Sendable {
        case media(trackID: CMPersistentTrackID, displaySize: SIMD2<Double>, orientation: Orientation, transfer: TransferFunction)
        case image(URL, displaySize: SIMD2<Double>)
        case text(TextContent)
        case caption(CaptionContent)
        case solid(RGBA)
    }
    public var itemID: ItemID
    public var source: Source
    public var transform: Transform
    public var opacity: Param<Double>
    /// Item placement on the timeline; keyframes are evaluated relative to `start`.
    public var start: RationalTime
    public var duration: RationalTime
    public var fadeIn: RationalTime
    public var fadeOut: RationalTime
    public var color: ColorAdjust = .none
    public var blend: BlendMode = .normal
    /// Transition opacity: (timeline seconds, multiplier) points, linear between them and held beyond. Empty = 1.
    public var envelope: [OpacityEnvelope.Point] = []

    /// Opacity including fades and transitions at item-relative time `t`.
    public func effectiveOpacity(at t: RationalTime) -> Double {
        var o = opacity.value(at: t)
        if fadeIn > .zero { o *= min(max(t.seconds / fadeIn.seconds, 0), 1) }
        if fadeOut > .zero { o *= min(max((duration - t).seconds / fadeOut.seconds, 0), 1) }
        if !envelope.isEmpty { o *= OpacityEnvelope.value(envelope, at: (start + t).seconds) }
        return o
    }
}

/// Piecewise-linear opacity over timeline time (used by transitions).
public enum OpacityEnvelope {
    public struct Point: Sendable, Equatable {
        public var time: Double
        public var value: Double
        public init(_ time: Double, _ value: Double) { self.time = time; self.value = value }
    }

    public static func value(_ points: [Point], at t: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 1 }
        if t <= first.time { return first.value }
        if t >= last.time { return last.value }
        for (a, b) in zip(points, points.dropFirst()) where t <= b.time {
            let span = b.time - a.time
            return span > 0 ? a.value + (b.value - a.value) * (t - a.time) / span : b.value
        }
        return last.value
    }
}

/// A span of the composition with a constant set of layers (bottom → top).
public final class RenderInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    public let timeRange: CMTimeRange
    public let enablePostProcessing = false
    public let containsTweening = true
    public let requiredSourceTrackIDs: [NSValue]?
    public let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    public let layers: [RenderLayer]
    public let context: RenderContext

    public init(timeRange: CMTimeRange, layers: [RenderLayer], context: RenderContext) {
        self.timeRange = timeRange
        self.layers = layers
        self.context = context
        let ids = layers.compactMap { l -> CMPersistentTrackID? in
            if case .media(let id, _, _, _) = l.source { id } else { nil }
        }
        requiredSourceTrackIDs = ids.isEmpty ? nil : ids.map { NSNumber(value: $0) }
    }
}
