import Foundation

/// A JSON document as a Sendable value: what the Python worker sends and receives.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Access

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { o[key] } else { nil }
    }

    public subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, a.indices.contains(index) { a[index] } else { nil }
    }

    public var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    public var doubleValue: Double? { if case .number(let n) = self { n } else { nil } }
    /// The number as an `Int` when it is integral and in range.
    public var intValue: Int? {
        guard case .number(let n) = self, n.rounded() == n, abs(n) < 9.0e15 else { return nil }
        return Int(n)
    }
    public var boolValue: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { o } else { nil } }
    public var isNull: Bool { self == .null }

    // MARK: Bridging

    /// Converts a `JSONSerialization` object graph.
    public init(any value: Any) throws {
        switch value {
        case is NSNull: self = .null
        case let n as NSNumber:
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(try a.map(JSONValue.init(any:)))
        case let o as [String: Any]: self = .object(try o.mapValues(JSONValue.init(any:)))
        default: throw JSONValueError.unsupported(String(describing: type(of: value)))
        }
    }

    /// A `JSONSerialization`-compatible object graph.
    public var anyValue: Any {
        switch self {
        case .null: NSNull()
        case .bool(let b): b
        case .number(let n): n.rounded() == n && abs(n) < 9.0e15 ? Int(n) as Any : n as Any
        case .string(let s): s
        case .array(let a): a.map(\.anyValue)
        case .object(let o): o.mapValues(\.anyValue)
        }
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONValue(any: JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    /// Compact single-line JSON (never contains a raw newline, so it is safe as one protocol line).
    public func serialized() throws -> Data {
        if case .number(let n) = self, !n.isFinite { throw JSONValueError.nonFinite }
        return try JSONSerialization.data(withJSONObject: anyValue, options: [.fragmentsAllowed, .sortedKeys,
                                                                               .withoutEscapingSlashes])
    }
}

public enum JSONValueError: Error, Sendable, Equatable {
    case unsupported(String)
    case nonFinite
}

extension JSONValue: CustomStringConvertible {
    public var description: String {
        (try? serialized()).map { String(decoding: $0, as: UTF8.self) } ?? "<invalid JSON>"
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
