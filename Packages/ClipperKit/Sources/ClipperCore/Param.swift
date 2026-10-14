import Foundation

/// Values that can be keyframed.
public protocol Animatable: Codable, Sendable, Equatable {
    static func interpolate(_ a: Self, _ b: Self, _ t: Double) -> Self
}

extension Double: Animatable {
    public static func interpolate(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
}

/// A point in normalized coordinates (0…1 across the canvas or source; y grows downward).
public struct NormPoint: Animatable, Hashable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public static let center = NormPoint(0.5, 0.5)
    public static func interpolate(_ a: NormPoint, _ b: NormPoint, _ t: Double) -> NormPoint {
        NormPoint(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
    }
}

public struct NormSize: Codable, Sendable, Hashable {
    public var width: Double
    public var height: Double
    public init(_ width: Double, _ height: Double) { self.width = width; self.height = height }
    public static let full = NormSize(1, 1)
}

/// A rectangle in normalized coordinates, origin top-left.
public struct NormRect: Codable, Sendable, Hashable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public static let full = NormRect(x: 0, y: 0, width: 1, height: 1)
    public var center: NormPoint { NormPoint(x + width / 2, y + height / 2) }
}

/// RGBA colour, encoded as `"#RRGGBB"` or `"#RRGGBBAA"`. Components are quantized to 8 bits on creation so
/// the in-memory value always equals what the document stores (save → load is exact).
public struct RGBA: Sendable, Hashable {
    public private(set) var r: Double, g: Double, b: Double, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        func q(_ x: Double) -> Double { (x.clamped(0, 1) * 255).rounded() / 255 }
        self.r = q(r); self.g = q(g); self.b = q(b); self.a = q(a)
    }
    public static let white = RGBA(1, 1, 1), black = RGBA(0, 0, 0), clear = RGBA(0, 0, 0, 0)

    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let full = s.count == 6 ? (v << 8 | 0xFF) : v
        self.init(Double((full >> 24) & 0xFF) / 255, Double((full >> 16) & 0xFF) / 255,
                  Double((full >> 8) & 0xFF) / 255, Double(full & 0xFF) / 255)
    }

    public var hex: String {
        let c = [r, g, b, a].map { Int(($0 * 255).rounded()).clamped(0, 255) }
        return c[3] == 255 ? String(format: "#%02X%02X%02X", c[0], c[1], c[2])
                           : String(format: "#%02X%02X%02X%02X", c[0], c[1], c[2], c[3])
    }
}

extension RGBA: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let v = RGBA(hex: s) else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad colour \(s)") }
        self = v
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hex)
    }
}

public enum Interpolation: String, Codable, Sendable {
    case hold, linear, easeInOut, easeOut, easeIn

    func apply(_ u: Double) -> Double {
        switch self {
        case .hold: 0
        case .linear: u
        case .easeInOut: u * u * (3 - 2 * u)
        case .easeOut: 1 - (1 - u) * (1 - u)
        case .easeIn: u * u
        }
    }
}

public struct Keyframe<Value: Animatable>: Codable, Sendable, Equatable {
    /// Time relative to the owning item's start.
    public var time: RationalTime
    public var value: Value
    /// Interpolation from this keyframe to the next.
    public var interpolation: Interpolation

    public init(_ time: RationalTime, _ value: Value, _ interpolation: Interpolation = .easeInOut) {
        self.time = time; self.value = value; self.interpolation = interpolation
    }
}

/// A property that is either constant or keyframed. Encodes as the bare value when constant,
/// or `{"keys": [...]}` when animated, keeping hand-edited JSON readable.
public enum Param<Value: Animatable>: Sendable, Equatable {
    case constant(Value)
    case keyframes([Keyframe<Value>])

    public func value(at t: RationalTime) -> Value {
        switch self {
        case .constant(let v): return v
        case .keyframes(let keys):
            guard let first = keys.first else { fatalError("Param.keyframes must not be empty") }
            if t <= first.time { return first.value }
            for (a, b) in zip(keys, keys.dropFirst()) where t < b.time {
                let span = (b.time - a.time).seconds
                let u = span > 0 ? (t - a.time).seconds / span : 1
                return Value.interpolate(a.value, b.value, a.interpolation.apply(min(max(u, 0), 1)))
            }
            return keys.last!.value
        }
    }

    public var isAnimated: Bool { if case .keyframes = self { true } else { false } }

    public var keys: [Keyframe<Value>] {
        if case .keyframes(let k) = self { k } else { [] }
    }

    /// Builds a param from keyframes, collapsing to a constant when there are none or all values match.
    public static func from(_ keys: [Keyframe<Value>]) -> Param<Value> {
        let sorted = keys.sorted { $0.time < $1.time }
        guard let first = sorted.first else { fatalError("Param.from needs at least one keyframe") }
        return sorted.allSatisfy({ $0.value == first.value }) ? .constant(first.value) : .keyframes(sorted)
    }
}

extension Param: Codable {
    private enum Keys: String, CodingKey { case keys }

    public init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: Keys.self), keyed.contains(.keys) {
            let k = try keyed.decode([Keyframe<Value>].self, forKey: .keys)
            guard !k.isEmpty else { throw DecodingError.dataCorruptedError(forKey: .keys, in: keyed, debugDescription: "empty keys") }
            self = .keyframes(k.sorted { $0.time < $1.time })
        } else {
            self = .constant(try decoder.singleValueContainer().decode(Value.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .constant(let v):
            var c = encoder.singleValueContainer()
            try c.encode(v)
        case .keyframes(let k):
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(k, forKey: .keys)
        }
    }
}

extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { min(max(self, lo), hi) }
}

// MARK: - Keyframe editing

extension Param {
    /// The keyframe at `t` (item-relative), if one is within `tolerance` (half a frame, typically).
    public func key(at t: RationalTime, tolerance: RationalTime) -> Keyframe<Value>? {
        keys.first { abs(($0.time - t).seconds) <= tolerance.seconds }
    }

    /// Sets a keyframe at `t`: replaces one within `tolerance`, else adds one. A constant becomes a single keyframe
    /// (still constant in effect) so the next key the user adds starts the animation from it.
    public func setting(_ value: Value, at t: RationalTime, tolerance: RationalTime, interpolation: Interpolation = .easeInOut) -> Param {
        var k = keys.filter { abs(($0.time - t).seconds) > tolerance.seconds }
        let existing = key(at: t, tolerance: tolerance)
        k.append(Keyframe(existing?.time ?? t, value, existing?.interpolation ?? interpolation))
        return .keyframes(k.sorted { $0.time < $1.time })
    }

    /// Removes the keyframe at `t`; removing the last one leaves the value it had as a constant.
    public func removingKey(at t: RationalTime, tolerance: RationalTime) -> Param {
        guard case .keyframes(let k) = self else { return self }
        let rest = k.filter { abs(($0.time - t).seconds) > tolerance.seconds }
        if rest.count == k.count { return self }
        return rest.isEmpty ? .constant(value(at: t)) : .keyframes(rest)
    }
}

extension Item {
    /// Item-relative times of every visual keyframe (position, scale, rotation, zoom, focus, opacity) — what the
    /// timeline marks on the clip. Gain keys are left out: ducking writes dozens of them.
    public var visualKeyframeTimes: [RationalTime] {
        let t = transform
        let all = t.position.keys.map(\.time) + t.scale.keys.map(\.time) + t.rotation.keys.map(\.time)
            + t.zoom.keys.map(\.time) + t.focus.keys.map(\.time) + opacity.keys.map(\.time)
        return Array(Set(all)).sorted()
    }
}
