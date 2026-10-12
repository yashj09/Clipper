import Foundation

/// Exact media time as `value / scale` seconds. Mirrors `CMTime` without depending on CoreMedia, so the model
/// stays pure and testable. Equality and ordering are by value: `1/2 == 30/60`.
public struct RationalTime: Sendable, Comparable, CustomStringConvertible {
    public var value: Int64
    public var scale: Int32

    /// Default timescale for times derived from seconds. Divisible by 24, 25, 30, 48, 50 and 60 and by the
    /// NTSC rates' 1001 denominators' numerators (24000, 30000, 60000), so common frame boundaries are exact.
    public static let defaultScale: Int32 = 60_000

    public static let zero = RationalTime(value: 0, scale: 1)

    public init(value: Int64, scale: Int32) {
        precondition(scale > 0, "RationalTime scale must be positive")
        self.value = value
        self.scale = scale
    }

    public init(seconds: Double, scale: Int32 = RationalTime.defaultScale) {
        self.init(value: Int64((seconds * Double(scale)).rounded()), scale: scale)
    }

    public var seconds: Double { Double(value) / Double(scale) }
    public var description: String { "\(value)/\(scale)" }

    /// The same instant expressed at `newScale`, rounded to the nearest representable value.
    public func rescaled(to newScale: Int32) -> RationalTime {
        if newScale == scale { return self }
        let v = (Double(value) * Double(newScale) / Double(scale)).rounded()
        return RationalTime(value: Int64(v), scale: newScale)
    }

    /// Reduced to lowest terms (used for hashing so equal instants hash equally).
    public var reduced: RationalTime {
        let g = gcd(abs(value), Int64(scale))
        guard g > 1 else { return self }
        return RationalTime(value: value / g, scale: Int32(Int64(scale) / g))
    }

    static func commonScale(_ a: Int32, _ b: Int32) -> Int32 {
        if a == b { return a }
        let l = Int64(a) / gcd(Int64(a), Int64(b)) * Int64(b)
        return l <= Int64(Int32.max) ? Int32(l) : Swift.max(a, b)
    }

    public static func + (a: RationalTime, b: RationalTime) -> RationalTime {
        let s = commonScale(a.scale, b.scale)
        return RationalTime(value: a.rescaled(to: s).value + b.rescaled(to: s).value, scale: s)
    }

    public static func - (a: RationalTime, b: RationalTime) -> RationalTime {
        let s = commonScale(a.scale, b.scale)
        return RationalTime(value: a.rescaled(to: s).value - b.rescaled(to: s).value, scale: s)
    }

    public static prefix func - (a: RationalTime) -> RationalTime { RationalTime(value: -a.value, scale: a.scale) }
    public static func += (a: inout RationalTime, b: RationalTime) { a = a + b }
    public static func -= (a: inout RationalTime, b: RationalTime) { a = a - b }

    /// Scales a duration by a real factor (e.g. playback speed), rounding at this time's scale.
    public static func * (a: RationalTime, k: Double) -> RationalTime {
        RationalTime(value: Int64((Double(a.value) * k).rounded()), scale: a.scale)
    }

    public static func < (a: RationalTime, b: RationalTime) -> Bool { compare(a, b) < 0 }

    public static func == (a: RationalTime, b: RationalTime) -> Bool { compare(a, b) == 0 }

    /// Exact comparison of `a.value / a.scale` with `b.value / b.scale` via 128-bit cross products, so it can't
    /// overflow for any timescale (AVPlayer reports nanoseconds: 9.2 s × 1e9 × 1e9 already exceeds Int64).
    static func compare(_ a: RationalTime, _ b: RationalTime) -> Int {
        if a.scale == b.scale { return a.value < b.value ? -1 : (a.value == b.value ? 0 : 1) }
        let l = a.value.multipliedFullWidth(by: Int64(b.scale))
        let r = b.value.multipliedFullWidth(by: Int64(a.scale))
        if l.high != r.high { return l.high < r.high ? -1 : 1 }
        if l.low != r.low { return l.low < r.low ? -1 : 1 }
        return 0
    }

    public static func min(_ a: RationalTime, _ b: RationalTime) -> RationalTime { a < b ? a : b }
    public static func max(_ a: RationalTime, _ b: RationalTime) -> RationalTime { a < b ? b : a }

    /// Snaps to the nearest frame boundary of `rate`, expressed in the rate's natural timescale.
    public func roundedToFrame(_ rate: FrameRate) -> RationalTime {
        let frames = (seconds / rate.frameDuration.seconds).rounded()
        return rate.time(ofFrame: Int64(frames))
    }

    public func floorToFrame(_ rate: FrameRate) -> RationalTime {
        let frames = (seconds / rate.frameDuration.seconds + 1e-9).rounded(.down)
        return rate.time(ofFrame: Int64(frames))
    }
}

extension RationalTime: Hashable {
    public func hash(into hasher: inout Hasher) {
        let r = reduced
        hasher.combine(r.value)
        hasher.combine(r.scale)
    }
}

/// Encoded as the string `"value/scale"`: exact and still readable in project JSON.
extension RationalTime: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            let parts = s.split(separator: "/")
            guard parts.count == 2, let v = Int64(parts[0]), let sc = Int32(parts[1]), sc > 0 else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Expected \"value/scale\", got \(s)")
            }
            self.init(value: v, scale: sc)
        } else {
            // Convenience for hand-written templates: plain seconds.
            self.init(seconds: try c.decode(Double.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

/// A half-open range `[start, start + duration)`.
public struct TimeRange: Codable, Hashable, Sendable, CustomStringConvertible {
    public var start: RationalTime
    public var duration: RationalTime

    public init(start: RationalTime, duration: RationalTime) {
        self.start = start
        self.duration = duration
    }

    public init(start: RationalTime, end: RationalTime) {
        self.init(start: start, duration: end - start)
    }

    public init(seconds start: Double, _ end: Double) {
        self.init(start: RationalTime(seconds: start), end: RationalTime(seconds: end))
    }

    public var end: RationalTime { start + duration }
    public var isEmpty: Bool { duration.value <= 0 }
    public var description: String { String(format: "[%.3f, %.3f)", start.seconds, end.seconds) }

    public func contains(_ t: RationalTime) -> Bool { t >= start && t < end }
    public func overlaps(_ o: TimeRange) -> Bool { start < o.end && o.start < end }

    public func intersection(_ o: TimeRange) -> TimeRange? {
        let s = RationalTime.max(start, o.start), e = RationalTime.min(end, o.end)
        return s < e ? TimeRange(start: s, end: e) : nil
    }

    public func offset(by d: RationalTime) -> TimeRange { TimeRange(start: start + d, duration: duration) }
}

/// A frame rate as an exact fraction, e.g. `30/1` or `30000/1001`.
public struct FrameRate: Codable, Hashable, Sendable, CustomStringConvertible {
    public var numerator: Int32
    public var denominator: Int32

    public init(_ numerator: Int32, _ denominator: Int32 = 1) {
        self.numerator = numerator
        self.denominator = denominator
    }

    public static let fps24 = FrameRate(24), fps25 = FrameRate(25), fps30 = FrameRate(30), fps60 = FrameRate(60)
    public static let ntsc30 = FrameRate(30000, 1001), ntsc60 = FrameRate(60000, 1001), film = FrameRate(24000, 1001)

    public var fps: Double { Double(numerator) / Double(denominator) }
    public var frameDuration: RationalTime { RationalTime(value: Int64(denominator), scale: numerator) }
    public func time(ofFrame n: Int64) -> RationalTime { RationalTime(value: n * Int64(denominator), scale: numerator) }
    public func frame(at t: RationalTime) -> Int64 { Int64((t.seconds * fps + 1e-6).rounded(.down)) }
    public var description: String { denominator == 1 ? "\(numerator)" : String(format: "%.3f", fps) }

    /// The closest standard rate to a measured (possibly variable) rate, e.g. 29.55 → 30.
    public static func nearestStandard(to fps: Double) -> FrameRate {
        let candidates: [FrameRate] = [.film, .fps24, .fps25, .ntsc30, .fps30, FrameRate(50), .ntsc60, .fps60, FrameRate(120)]
        return candidates.min { abs($0.fps - fps) < abs($1.fps - fps) }!
    }
}

func gcd(_ a: Int64, _ b: Int64) -> Int64 {
    var (a, b) = (abs(a), abs(b))
    while b != 0 { (a, b) = (b, a % b) }
    return max(a, 1)
}

extension Duration {
    /// Seconds as a Double (for timing and progress reporting).
    public var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
