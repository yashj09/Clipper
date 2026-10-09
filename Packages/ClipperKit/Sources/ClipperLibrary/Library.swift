import ClipperCore
import Foundation
import GRDB

/// Errors raised by the library bundle.
public enum LibraryError: Error, Equatable, CustomStringConvertible {
    case alreadyExists(URL)
    case notALibrary(URL)
    case projectNotFound(UUID)
    case assetNotFound(AssetID)
    case jobNotFound(UUID)
    case invalidIdentifier(String)

    public var description: String {
        switch self {
        case .alreadyExists(let url): "A file already exists at \(url.path)"
        case .notALibrary(let url): "\(url.path) is not a Clipper library"
        case .projectNotFound(let id): "No project with id \(id)"
        case .assetNotFound(let id): "No asset with id \(id)"
        case .jobNotFound(let id): "No job with id \(id)"
        case .invalidIdentifier(let s): "\"\(s)\" can't be used as a file name"
        }
    }
}

/// A `.clipperlib` bundle: a GRDB index (`index.sqlite`, WAL) plus JSON documents and media folders.
///
/// Thread-safe: every stored property is immutable and the `DatabasePool` serializes writes, so one instance can be
/// shared between the main actor and background tasks. Several instances (e.g. the app and the `clipper` CLI) may
/// open the same bundle at once; SQLite/WAL arbitrates, with a busy timeout for concurrent writers.
public final class Library: Sendable {
    public static let fileExtension = "clipperlib"

    public let url: URL
    let dbPool: DatabasePool

    /// Analysis results stored under `Cache/<assetKey>/<analyzer>@<version>.json`, indexed in the `analysis` table.
    public var analysisCache: any AnalysisCache { LibraryAnalysisCache(library: self) }

    // MARK: Layout

    public var indexURL: URL { url.appending(path: "index.sqlite", directoryHint: .notDirectory) }
    public var projectsURL: URL { url.appending(path: "Projects", directoryHint: .isDirectory) }
    public var backupsURL: URL { projectsURL.appending(path: ".backups", directoryHint: .isDirectory) }
    public var mediaURL: URL { url.appending(path: "Media", directoryHint: .isDirectory) }
    public var proxiesURL: URL { url.appending(path: "Proxies", directoryHint: .isDirectory) }
    public var cacheURL: URL { url.appending(path: "Cache", directoryHint: .isDirectory) }
    public var templatesURL: URL { url.appending(path: "Templates", directoryHint: .isDirectory) }
    public var exportsURL: URL { url.appending(path: "Exports", directoryHint: .isDirectory) }

    /// Folder for generated proxies of one asset (reserved; nothing writes here yet).
    public func proxiesURL(for key: AssetKey) throws -> URL {
        proxiesURL.appending(path: try Library.safeComponent(key.rawValue), directoryHint: .isDirectory)
    }

    /// Where exports go: the settings override if set, else the bundle's `Exports/` folder.
    public func exportFolder() throws -> URL { try settings().export.outputFolder ?? exportsURL }

    static let subfolders = ["Projects", "Projects/.backups", "Media", "Proxies", "Cache", "Templates", "Exports"]

    // MARK: Opening

    /// `~/Movies/Clipper/Clipper.clipperlib`
    public static var defaultURL: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies", directoryHint: .isDirectory)
        return movies.appending(path: "Clipper", directoryHint: .isDirectory)
            .appending(path: "Clipper.\(fileExtension)", directoryHint: .isDirectory)
    }

    private init(url: URL) throws {
        self.url = url.standardizedFileURL
        var config = Configuration()
        config.label = "ClipperLibrary"
        // Another process (app vs CLI) may hold the write lock; wait instead of failing immediately.
        config.busyMode = .timeout(10)
        dbPool = try DatabasePool(path: self.url.appending(path: "index.sqlite", directoryHint: .notDirectory).path,
                                  configuration: config)
        try Schema.migrator.migrate(dbPool)
    }

    /// Creates a new, empty library. Fails if anything already exists at `url`.
    public static func create(at url: URL) throws -> Library {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { throw LibraryError.alreadyExists(url) }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            // Not intermediate: fails if another process created the bundle since the check above.
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
        } catch CocoaError.fileWriteFileExists {
            throw LibraryError.alreadyExists(url)
        }
        do {
            try createSubfolders(in: url)
            return try Library(url: url)
        } catch {
            try? fm.removeItem(at: url)
            throw error
        }
    }

    /// Opens an existing library and applies any pending schema migrations.
    public static func open(at url: URL) throws -> Library {
        var isDir: ObjCBool = false
        let index = url.appending(path: "index.sqlite", directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
              FileManager.default.fileExists(atPath: index.path)
        else { throw LibraryError.notALibrary(url) }
        try createSubfolders(in: url)   // tolerate bundles missing a folder (e.g. emptied by hand)
        return try Library(url: url)
    }

    public static func openOrCreate(at url: URL) throws -> Library {
        if FileManager.default.fileExists(atPath: url.path) { return try open(at: url) }
        do { return try create(at: url) } catch LibraryError.alreadyExists { return try open(at: url) }
    }

    private static func createSubfolders(in url: URL) throws {
        for sub in subfolders {
            try FileManager.default.createDirectory(at: url.appending(path: sub, directoryHint: .isDirectory),
                                                    withIntermediateDirectories: true)
        }
    }

    // MARK: Paths stored in the index

    /// Files inside the bundle are stored relative to it (so the bundle can move); others as absolute paths.
    func storedPath(for fileURL: URL) -> String {
        let path = fileURL.standardizedFileURL.path
        let root = url.path.hasSuffix("/") ? url.path : url.path + "/"
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    func resolvePath(_ stored: String) -> URL {
        if stored.hasPrefix("/") { return URL(filePath: stored, directoryHint: .notDirectory) }
        let root = url.path.hasSuffix("/") ? url.path : url.path + "/"
        return URL(filePath: root + stored, directoryHint: .notDirectory)
    }

    /// Validates a string used as a single path component (template ids, analyzer names, asset keys).
    static func safeComponent(_ s: String) throws -> String {
        guard !s.isEmpty, !s.hasPrefix("."), !s.contains("/"), !s.contains(":"), !s.contains("\0")
        else { throw LibraryError.invalidIdentifier(s) }
        return s
    }

    /// Atomic write that creates the parent folder if needed.
    static func writeAtomically(_ data: Data, to fileURL: URL) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}

extension Date {
    var dbValue: Double { timeIntervalSinceReferenceDate }
    init(dbValue: Double) { self.init(timeIntervalSinceReferenceDate: dbValue) }
}
