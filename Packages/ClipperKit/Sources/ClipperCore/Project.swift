import Foundation

/// A project document: one or more timelines (e.g. several shorts cut from one VOD).
public struct Project: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var name: String
    public var created: Date
    public var modified: Date
    public var timelines: [Timeline]

    public init(id: UUID = UUID(), name: String, timelines: [Timeline] = [], created: Date = Date()) {
        self.schemaVersion = Project.currentSchemaVersion
        self.id = id; self.name = name; self.created = created; self.modified = created; self.timelines = timelines
    }
}

public enum ProjectError: Error, CustomStringConvertible {
    case newerSchema(Int)
    public var description: String {
        switch self { case .newerSchema(let v): "Project schema v\(v) is newer than this app supports (v\(Project.currentSchemaVersion))" }
    }
}

/// JSON coding shared by every document type, so files diff cleanly and round-trip byte-for-byte.
public enum ClipperJSON {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data { try encoder().encode(value) }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T { try decoder().decode(type, from: data) }

    /// Decodes a project, applying schema migrations (pure JSON → JSON functions) when it is older.
    public static func decodeProject(_ data: Data) throws -> Project {
        struct Header: Decodable { var schemaVersion: Int }
        let version = try decoder().decode(Header.self, from: data).schemaVersion
        guard version <= Project.currentSchemaVersion else { throw ProjectError.newerSchema(version) }
        var json = data
        for v in version..<Project.currentSchemaVersion { json = try migrations[v](json) }
        return try decoder().decode(Project.self, from: json)
    }

    /// `migrations[n]` upgrades schema n → n+1. Empty while we are on v1.
    static let migrations: [@Sendable (Data) throws -> Data] = []
}

/// Deterministic UUIDs from a seed, so the same draft inputs produce byte-identical timelines.
public struct IDGenerator: Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    public mutating func next() -> UInt64 {
        // SplitMix64
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    public mutating func uuid() -> UUID {
        let a = next(), b = next()
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 { bytes[i] = UInt8((a >> (8 * UInt64(i))) & 0xFF); bytes[8 + i] = UInt8((b >> (8 * UInt64(i))) & 0xFF) }
        bytes[6] = (bytes[6] & 0x0F) | 0x40   // version 4 layout
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Uniform double in [0, 1).
    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
