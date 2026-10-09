import ClipperCore
import Foundation
import GRDB

public enum ImportMode: String, Codable, Sendable {
    /// Copy the file into the bundle's `Media/` folder.
    case copy
    /// Leave the file where it is; store its path plus a bookmark for relinking.
    case reference
}

/// One row of the `asset` table.
struct AssetRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "asset"

    var id: String
    var key: String
    var name: String
    var kind: String
    var path: String
    var bookmark: Data?
    var managed: Bool
    var imported: Double
    var info: String
    var tags: String
    var playablePath: String?
    var proxyPath: String?

    enum Columns {
        static let id = Column("id"), key = Column("key"), managed = Column("managed"), imported = Column("imported")
        static let name = Column("name")
    }

    static let ordered = AssetRow.order(Columns.imported, Columns.name)

    func asset(in library: Library) throws -> MediaAsset {
        MediaAsset(
            id: UUID(uuidString: id) ?? UUID(),
            key: AssetKey(key),
            name: name,
            url: library.resolvePath(path),
            info: try ClipperJSON.decode(MediaInfo.self, from: Data(info.utf8)),
            playableURL: playablePath.map(library.resolvePath),
            proxyURL: proxyPath.map(library.resolvePath),
            tags: try ClipperJSON.decode([String].self, from: Data(tags.utf8)))
    }

    /// Copies the mutable fields of `asset` into the row (id, key, managed flag and import date are kept).
    mutating func apply(_ asset: MediaAsset, in library: Library) throws {
        name = asset.name
        kind = asset.info.kind.rawValue
        path = library.storedPath(for: asset.url)
        info = try jsonText(asset.info)
        tags = try jsonText(asset.tags)
        playablePath = asset.playableURL.map(library.storedPath)
        proxyPath = asset.proxyURL.map(library.storedPath)
    }
}

func jsonText<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try ClipperJSON.encode(value), as: UTF8.self)
}

extension Library {
    // MARK: Import

    /// Imports files. `probe` turns a file URL into a `MediaAsset` (in the app/CLI: `ClipperEngine.MediaProbe.makeAsset`).
    ///
    /// Dedupes by `AssetKey`: importing the same content twice returns the existing asset. In copy mode the file is
    /// copied into `Media/` (Finder-style " 2" suffix on name collisions) and the asset's url points at the copy; in
    /// reference mode the original path and a bookmark are stored. Safe to call concurrently (also across processes)
    /// with the same file: the unique index on `key` decides the winner and the loser returns the winner's asset.
    /// Throws on the first file that fails; files imported before it stay imported.
    public func importMedia(_ urls: [URL], mode: ImportMode,
                            probe: @Sendable (URL) async throws -> MediaAsset) async throws -> [MediaAsset] {
        var result: [MediaAsset] = []
        for source in urls {
            let probed = try await probe(source)
            if let existing = try await dbPool.read({ db in try AssetRow.filter(AssetRow.Columns.key == probed.key.rawValue).fetchOne(db) }) {
                result.append(try existing.asset(in: self))
                continue
            }

            var fileURL = source.standardizedFileURL
            var bookmark: Data?
            switch mode {
            case .copy:
                fileURL = try copyIntoMedia(source)
            case .reference:
                bookmark = Library.makeBookmark(for: fileURL)
            }

            var row = AssetRow(id: probed.id.uuidString, key: probed.key.rawValue, name: probed.name, kind: "",
                               path: "", bookmark: bookmark, managed: mode == .copy, imported: Date().dbValue,
                               info: "", tags: "", playablePath: nil, proxyPath: nil)
            var asset = probed
            asset.url = fileURL
            try row.apply(asset, in: self)

            let insertedRow = row
            let stored: AssetRow = try await dbPool.write { db in
                try insertedRow.insert(db, onConflict: .ignore)
                guard let r = try AssetRow.filter(AssetRow.Columns.key == insertedRow.key).fetchOne(db) else {
                    throw LibraryError.assetNotFound(probed.id)   // id collision with a different key
                }
                return r
            }
            if stored.id != row.id, mode == .copy {
                // Lost an import race: someone else stored this content first. Drop our copy.
                try? FileManager.default.removeItem(at: fileURL)
            }
            result.append(try stored.asset(in: self))
        }
        return result
    }

    /// Copies `source` into `Media/`, keeping its name and adding " 2", " 3"… if taken.
    private func copyIntoMedia(_ source: URL) throws -> URL {
        let ext = source.pathExtension
        let base = source.deletingPathExtension().lastPathComponent
        for n in 1... {
            let name = (n == 1 ? base : "\(base) \(n)") + (ext.isEmpty ? "" : ".\(ext)")
            let dest = mediaURL.appending(path: name, directoryHint: .notDirectory)
            do {
                // copyItem fails if `dest` exists, which makes the name reservation race-free. APFS clones the file.
                try FileManager.default.copyItem(at: source, to: dest)
                return dest
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        fatalError("unreachable")
    }

    static func makeBookmark(for url: URL) -> Data? {
        // Security-scoped bookmarks need the sandbox; a plain bookmark still survives moves on the same volume.
        (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
    }

    static func resolveBookmark(_ data: Data) -> (url: URL, stale: Bool)? {
        for options: URL.BookmarkResolutionOptions in [[.withSecurityScope, .withoutUI], [.withoutUI]] {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale) {
                return (url, stale)
            }
        }
        return nil
    }

    // MARK: Queries

    public func assets() throws -> [MediaAsset] {
        try dbPool.read { db in try AssetRow.ordered.fetchAll(db) }.map { try $0.asset(in: self) }
    }

    public func asset(_ id: AssetID) throws -> MediaAsset? {
        try dbPool.read { db in try AssetRow.fetchOne(db, key: id.uuidString) }.map { try $0.asset(in: self) }
    }

    public func asset(key: AssetKey) throws -> MediaAsset? {
        try dbPool.read { db in try AssetRow.filter(AssetRow.Columns.key == key.rawValue).fetchOne(db) }
            .map { try $0.asset(in: self) }
    }

    /// Whether the asset's file lives in the bundle's `Media/` folder (imported with `.copy`).
    public func isManaged(_ id: AssetID) throws -> Bool {
        try dbPool.read { db in try AssetRow.fetchOne(db, key: id.uuidString)?.managed } ?? false
    }

    // MARK: Mutation

    /// Saves changed fields (name, url, playable/proxy URLs, tags, info). The key, managed flag and import date are
    /// fixed. A changed url of a referenced asset gets a fresh bookmark.
    public func updateAsset(_ asset: MediaAsset) throws {
        try dbPool.write { db in
            guard var row = try AssetRow.fetchOne(db, key: asset.id.uuidString) else { throw LibraryError.assetNotFound(asset.id) }
            let oldPath = row.path
            try row.apply(asset, in: self)
            if !row.managed, row.path != oldPath { row.bookmark = Library.makeBookmark(for: asset.url) }
            try row.update(db)
        }
    }

    /// Removes the asset from the index. With `deleteManagedFile`, a copied-in file (and its proxies) is deleted too;
    /// referenced files are never deleted. Analysis cache entries are kept (they are keyed by content).
    public func removeAsset(_ id: AssetID, deleteManagedFile: Bool) throws {
        let row = try dbPool.write { db -> AssetRow? in
            let row = try AssetRow.fetchOne(db, key: id.uuidString)
            try AssetRow.deleteOne(db, key: id.uuidString)
            return row
        }
        guard let row, deleteManagedFile, row.managed else { return }
        let file = resolvePath(row.path)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        if let proxies = try? proxiesURL(for: AssetKey(row.key)), FileManager.default.fileExists(atPath: proxies.path) {
            try FileManager.default.removeItem(at: proxies)
        }
    }

    // MARK: Relink

    /// Re-resolves referenced assets whose file moved via their bookmark and updates the stored path.
    /// Returns the assets still missing (referenced or managed).
    @discardableResult
    public func relink() throws -> [MediaAsset] { try relinkByBookmark().map(\.asset) }

    /// Relinks missing referenced assets by content: files under `searchFolders` (recursively) whose key, computed by
    /// `key` (e.g. `MediaProbe.assetKey`), matches a missing asset's key. Returns the assets still missing.
    @discardableResult
    public func relink(searchFolders: [URL], key: @Sendable (URL) async throws -> AssetKey) async throws -> [MediaAsset] {
        var missing = try relinkByBookmark().filter { !$0.managed }.map(\.asset)
        for folder in searchFolders where !missing.isEmpty {
            for file in Library.regularFiles(in: folder) where !missing.isEmpty {
                guard let k = try? await key(file), let i = missing.firstIndex(where: { $0.key == k }) else { continue }
                var asset = missing.remove(at: i)
                asset.url = file.standardizedFileURL
                try updateAsset(asset)   // also refreshes the bookmark
            }
        }
        return try relink()
    }

    private func relinkByBookmark() throws -> [(asset: MediaAsset, managed: Bool)] {
        let rows = try dbPool.read { db in try AssetRow.ordered.fetchAll(db) }
        let fm = FileManager.default
        var missing: [(MediaAsset, Bool)] = []
        for var row in rows {
            if row.managed {
                if !fm.fileExists(atPath: resolvePath(row.path).path) { missing.append((try row.asset(in: self), true)) }
                continue
            }
            if let resolved = row.bookmark.flatMap(Library.resolveBookmark), fm.fileExists(atPath: resolved.url.path) {
                let newPath = storedPath(for: resolved.url)
                guard newPath != row.path || resolved.stale else { continue }
                row.path = newPath
                row.bookmark = Library.makeBookmark(for: resolved.url) ?? row.bookmark
                let updated = row
                try dbPool.write { db in try updated.update(db) }
            } else if !fm.fileExists(atPath: resolvePath(row.path).path) {
                missing.append((try row.asset(in: self), false))
            }
        }
        return missing
    }

    private static func regularFiles(in folder: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        return walker.compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }
}
