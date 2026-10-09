import ClipperCore
import Foundation
import GRDB
import os

private let log = Logger(subsystem: "com.clipper.library", category: "documents")

struct MusicRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "music"
    var id: String
    var title: String
    var artist: String
    var track: String
    var updated: Double
}

struct SettingsRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "settings"
    var id: Int = 1
    var json: String
}

extension Library {
    // MARK: Templates (user ones; built-ins come from ClipperAutomation and are merged by callers)

    public func templateURL(id: String) throws -> URL {
        templatesURL.appending(path: "\(try Library.safeComponent(id)).json", directoryHint: .notDirectory)
    }

    /// User templates sorted by name. Files that fail to decode are skipped (and logged) so one bad file doesn't
    /// hide the rest.
    public func userTemplates() throws -> [Template] {
        let files = try FileManager.default.contentsOfDirectory(at: templatesURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .filter { $0.pathExtension == "json" }
        return files.compactMap { file -> Template? in
            do { return try ClipperJSON.decode(Template.self, from: Data(contentsOf: file)) } catch {
                log.error("Skipping unreadable template \(file.lastPathComponent, privacy: .public): \(error, privacy: .public)")
                return nil
            }
        }
        .sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    public func saveTemplate(_ t: Template) throws {
        try Library.writeAtomically(try ClipperJSON.encode(t), to: try templateURL(id: t.id))
    }

    public func deleteTemplate(id: String) throws {
        let file = try templateURL(id: id)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    // MARK: Music

    /// Inserts or replaces tracks by id (user tracks and built-in packs alike).
    public func upsertMusic(_ tracks: [MusicTrack]) throws {
        let now = Date().dbValue
        let rows = try tracks.map { MusicRow(id: $0.id, title: $0.title, artist: $0.artist, track: try jsonText($0), updated: now) }
        try dbPool.write { db in for row in rows { try row.upsert(db) } }
    }

    /// All tracks, sorted by title.
    public func music() throws -> [MusicTrack] {
        try dbPool.read { db in try MusicRow.order(Column("title"), Column("id")).fetchAll(db) }
            .map { try ClipperJSON.decode(MusicTrack.self, from: Data($0.track.utf8)) }
    }

    public func deleteMusic(ids: [String]) throws {
        _ = try dbPool.write { db in try MusicRow.deleteAll(db, keys: ids) }
    }

    // MARK: Settings

    /// The library's settings; defaults when never saved. Decoding is tolerant (`ClipperSettings.init(from:)`).
    public func settings() throws -> ClipperSettings {
        guard let row = try dbPool.read({ db in try SettingsRow.fetchOne(db, key: 1) }) else { return ClipperSettings() }
        return try ClipperJSON.decode(ClipperSettings.self, from: Data(row.json.utf8))
    }

    public func saveSettings(_ s: ClipperSettings) throws {
        let row = SettingsRow(json: try jsonText(s))
        try dbPool.write { db in try row.upsert(db) }
    }
}
