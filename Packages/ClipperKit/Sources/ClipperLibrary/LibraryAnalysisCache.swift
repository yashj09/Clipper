import ClipperCore
import Foundation
import GRDB

/// One row of the `analysis` index: the cached version of an analyzer's result for one asset.
public struct AnalysisCacheEntry: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "analysis"
    public var assetKey: String
    public var analyzer: String
    public var version: Int
    public var bytes: Int
    public var updated: Double
}

/// `AnalysisCache` backed by `Cache/<assetKey>/<analyzer>@<version>.json` plus the `analysis` index table.
///
/// The file name carries the version, so a load reads the file directly (no index lookup) and a different version
/// is a miss. Storing a new version deletes the other versions' files for that analyzer.
struct LibraryAnalysisCache: AnalysisCache {
    let library: Library

    func fileURL(key: AssetKey, analyzer: String, version: Int) throws -> URL {
        try folder(key).appending(path: "\(try Library.safeComponent(analyzer))@\(version).json", directoryHint: .notDirectory)
    }

    func folder(_ key: AssetKey) throws -> URL {
        library.cacheURL.appending(path: try Library.safeComponent(key.rawValue), directoryHint: .isDirectory)
    }

    func load(key: AssetKey, analyzer: String, version: Int) async -> Data? {
        guard let file = try? fileURL(key: key, analyzer: analyzer, version: version) else { return nil }
        return try? Data(contentsOf: file)
    }

    func store(_ data: Data, key: AssetKey, analyzer: String, version: Int) async throws {
        let file = try fileURL(key: key, analyzer: analyzer, version: version)
        try Library.writeAtomically(data, to: file)
        let prefix = "\(analyzer)@"
        for other in (try? FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        where other.lastPathComponent.hasPrefix(prefix) && other.lastPathComponent != file.lastPathComponent {
            try? FileManager.default.removeItem(at: other)
        }
        let entry = AnalysisCacheEntry(assetKey: key.rawValue, analyzer: analyzer, version: version, bytes: data.count,
                                       updated: Date().dbValue)
        try await library.dbPool.write { db in try entry.upsert(db) }
    }
}

extension Library {
    /// Index entries of the analysis cache, optionally for one asset.
    public func analysisCacheEntries(for key: AssetKey? = nil) throws -> [AnalysisCacheEntry] {
        try dbPool.read { db in
            var request = AnalysisCacheEntry.order(Column("assetKey"), Column("analyzer"))
            if let key { request = request.filter(Column("assetKey") == key.rawValue) }
            return try request.fetchAll(db)
        }
    }

    /// Deletes every cached analysis result of one asset (files and index rows).
    public func removeAnalysisCache(for key: AssetKey) throws {
        let folder = try LibraryAnalysisCache(library: self).folder(key)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        _ = try dbPool.write { db in try AnalysisCacheEntry.filter(Column("assetKey") == key.rawValue).deleteAll(db) }
    }
}
