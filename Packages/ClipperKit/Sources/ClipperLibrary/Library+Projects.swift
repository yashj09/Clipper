import ClipperCore
import Foundation
import GRDB

/// A project as listed by the index (the document itself lives in `Projects/<id>.clipproj.json`).
public struct ProjectSummary: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var modified: Date
    public var timelineCount: Int

    public init(id: UUID, name: String, modified: Date, timelineCount: Int) {
        self.id = id; self.name = name; self.modified = modified; self.timelineCount = timelineCount
    }
}

struct ProjectRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "project"

    var id: String
    var name: String
    var created: Double
    var modified: Double
    var timelineCount: Int
    var path: String

    static let newestFirst = ProjectRow.order(Column("modified").desc, Column("name"))

    var summary: ProjectSummary {
        ProjectSummary(id: UUID(uuidString: id) ?? UUID(), name: name, modified: Date(dbValue: modified), timelineCount: timelineCount)
    }
}

extension Library {
    public static let maxProjectBackups = 10

    public func projectURL(_ id: UUID) -> URL {
        projectsURL.appending(path: "\(id.uuidString).clipproj.json", directoryHint: .notDirectory)
    }

    func backupFolder(_ id: UUID) -> URL {
        backupsURL.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    /// Writes the project atomically, keeping the previous file as a rolling backup (at most
    /// `maxProjectBackups`), bumps `modified`, and upserts the index.
    ///
    /// Returns the project exactly as stored (what `loadProject` will return; JSON dates have whole-second precision).
    @discardableResult
    public func saveProject(_ project: Project) throws -> Project {
        var project = project
        project.modified = Date()
        let data = try ClipperJSON.encode(project)
        let stored = try ClipperJSON.decodeProject(data)

        let file = projectURL(project.id)
        if FileManager.default.fileExists(atPath: file.path) { try backUp(file, of: project.id) }
        try Library.writeAtomically(data, to: file)

        let row = ProjectRow(id: stored.id.uuidString, name: stored.name, created: stored.created.dbValue,
                             modified: stored.modified.dbValue, timelineCount: stored.timelines.count,
                             path: storedPath(for: file))
        try dbPool.write { db in try row.upsert(db) }
        return stored
    }

    /// Loads a project document, applying schema migrations (`ClipperJSON.decodeProject`).
    public func loadProject(_ id: UUID) throws -> Project {
        let file = projectURL(id)
        guard FileManager.default.fileExists(atPath: file.path) else { throw LibraryError.projectNotFound(id) }
        return try ClipperJSON.decodeProject(try Data(contentsOf: file))
    }

    /// Projects, most recently modified first.
    public func projects() throws -> [ProjectSummary] {
        try dbPool.read { db in try ProjectRow.newestFirst.fetchAll(db) }.map(\.summary)
    }

    /// Deletes the document, its backups and its index row.
    public func deleteProject(_ id: UUID) throws {
        let fm = FileManager.default
        for url in [projectURL(id), backupFolder(id)] where fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        _ = try dbPool.write { db in try ProjectRow.deleteOne(db, key: id.uuidString) }
    }

    /// Backup files of a project, newest first.
    public func backups(of id: UUID) throws -> [URL] {
        let folder = backupFolder(id)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Re-indexes every document in `Projects/` (e.g. after files were copied in by hand). Unreadable files are skipped
    /// and index rows without a document are removed.
    public func rebuildProjectIndex() throws {
        let files = try FileManager.default.contentsOfDirectory(at: projectsURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .filter { $0.lastPathComponent.hasSuffix(".clipproj.json") }
        let rows: [ProjectRow] = files.compactMap { file in
            guard let data = try? Data(contentsOf: file), let p = try? ClipperJSON.decodeProject(data),
                  file.lastPathComponent == "\(p.id.uuidString).clipproj.json" else { return nil }
            return ProjectRow(id: p.id.uuidString, name: p.name, created: p.created.dbValue, modified: p.modified.dbValue,
                              timelineCount: p.timelines.count, path: storedPath(for: file))
        }
        try dbPool.write { db in
            try ProjectRow.deleteAll(db)
            for row in rows { try row.insert(db) }
        }
    }

    /// Copies the current document to `.backups/<id>/<UTC timestamp>.json` and prunes to `maxProjectBackups`.
    private func backUp(_ file: URL, of id: UUID) throws {
        let folder = backupFolder(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Timestamps sort lexicographically; bump by 1 ms when two saves land in the same millisecond.
        var date = Date()
        var dest = folder.appending(path: Library.backupName(date), directoryHint: .notDirectory)
        while FileManager.default.fileExists(atPath: dest.path) {
            date += 0.001
            dest = folder.appending(path: Library.backupName(date), directoryHint: .notDirectory)
        }
        try FileManager.default.copyItem(at: file, to: dest)
        for old in try backups(of: id).dropFirst(Library.maxProjectBackups) { try? FileManager.default.removeItem(at: old) }
    }

    /// `20261010T153012.345Z.json` (UTC, no colons so it is a valid file name everywhere).
    static func backupName(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let ms = Int((date.timeIntervalSince1970 * 1000).rounded(.down)) % 1000
        func pad(_ v: Int?, _ n: Int) -> String { String(String(repeating: "0", count: n) + String(v ?? 0)).suffix(n).description }
        return "\(pad(c.year, 4))\(pad(c.month, 2))\(pad(c.day, 2))T\(pad(c.hour, 2))\(pad(c.minute, 2))\(pad(c.second, 2)).\(pad(ms, 3))Z.json"
    }
}
