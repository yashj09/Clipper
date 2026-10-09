import ClipperCore
import CoreMedia

extension RationalTime {
    public var cmTime: CMTime { CMTime(value: value, timescale: scale) }

    public init(_ t: CMTime) {
        guard t.isNumeric, t.timescale > 0 else { self = .zero; return }
        self.init(value: t.value, scale: t.timescale)
    }
}

extension TimeRange {
    public var cmTimeRange: CMTimeRange { CMTimeRange(start: start.cmTime, duration: duration.cmTime) }
    public init(_ r: CMTimeRange) { self.init(start: RationalTime(r.start), duration: RationalTime(r.duration)) }
}

extension FrameRate {
    public var cmFrameDuration: CMTime { CMTime(value: CMTimeValue(denominator), timescale: numerator) }
}

/// Wraps non-Sendable framework objects we deliberately pass across isolation boundaries
/// (AVFoundation objects that are immutable after construction, or only touched on one queue).
public struct UncheckedSendable<T>: @unchecked Sendable {
    public let value: T
    public init(_ value: T) { self.value = value }
}
