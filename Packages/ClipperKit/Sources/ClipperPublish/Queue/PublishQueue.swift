import ClipperCore
import Foundation

/// A post planned for one or more platforms: which timeline to export, metadata, when, and what happened.
public struct ScheduledPost: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable { case scheduled, exporting, uploading, posted, partial, failed, cancelled }

    public var id: UUID
    public var projectID: UUID
    public var timelineIndex: Int
    public var platforms: [Platform]
    public var title: String
    public var description: String
    public var tags: [String]
    public var visibility: Visibility
    public var scheduledAt: Date
    public var presetID: String
    public var status: Status
    public var results: [PublishResult]
    public var errors: [String: String]
    public var exportedFile: URL?
    public var updated: Date

    public init(id: UUID = UUID(), projectID: UUID, timelineIndex: Int = 0, platforms: [Platform], title: String,
                description: String = "", tags: [String] = [], visibility: Visibility = .private, scheduledAt: Date,
                presetID: String = "shorts-1080x1920") {
        self.id = id; self.projectID = projectID; self.timelineIndex = timelineIndex; self.platforms = platforms
        self.title = title; self.description = description; self.tags = tags; self.visibility = visibility
        self.scheduledAt = scheduledAt; self.presetID = presetID; self.status = .scheduled; self.results = []
        self.errors = [:]; self.exportedFile = nil; self.updated = scheduledAt
    }

    /// Platforms still to do (not yet posted successfully).
    public var remainingPlatforms: [Platform] { platforms.filter { p in !results.contains { $0.platform == p } } }
}

/// The publishing queue, stored as one JSON document (e.g. `<library>/Publishing/queue.json`).
/// Writes are atomic; a lock file serializes the app and CLI (`run-due` from launchd) touching it at once.
public final class PublishQueue: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()

    public init(directory: URL) {
        url = directory.appendingPathComponent("queue.json")
    }

    public func posts() throws -> [ScheduledPost] {
        try lock.withLock { try load() }
    }

    /// Posts whose time has come and that still have platforms to do.
    public func due(at now: Date = Date()) throws -> [ScheduledPost] {
        try posts().filter { $0.scheduledAt <= now && ($0.status == .scheduled || $0.status == .partial) }
            .sorted { $0.scheduledAt < $1.scheduledAt }
    }

    public func add(_ post: ScheduledPost) throws { try mutate { $0.append(post) } }

    public func update(_ id: UUID, _ change: (inout ScheduledPost) -> Void) throws {
        try mutate { posts in
            guard let i = posts.firstIndex(where: { $0.id == id }) else { return }
            change(&posts[i])
            posts[i].updated = Date()
        }
    }

    public func remove(_ id: UUID) throws { try mutate { $0.removeAll { $0.id == id } } }

    // MARK: Storage

    private func mutate(_ body: (inout [ScheduledPost]) -> Void) throws {
        try lock.withLock {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Cross-process exclusion (app + CLI): an advisory lock on a sibling file.
            let lockPath = url.deletingLastPathComponent().appendingPathComponent(".queue.lock").path
            let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
            guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
            defer { flock(fd, LOCK_UN); close(fd) }
            flock(fd, LOCK_EX)
            var posts = try load()
            body(&posts)
            try ClipperJSON.encode(posts.sorted { $0.scheduledAt < $1.scheduledAt }).write(to: url, options: .atomic)
        }
    }

    private func load() throws -> [ScheduledPost] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try ClipperJSON.decode([ScheduledPost].self, from: Data(contentsOf: url))
    }
}

/// iCalendar (RFC 5545) feed of scheduled posts, for Apple Calendar / Google Calendar / Notion subscriptions.
public enum PublishCalendar {
    public static func ics(_ posts: [ScheduledPost], calendarName: String = "Clipper posts", duration: TimeInterval = 15 * 60,
                           now: Date = Date()) -> String {
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Clipper//Publishing//EN", "CALSCALE:GREGORIAN",
                     "METHOD:PUBLISH", "X-WR-CALNAME:\(escape(calendarName))"]
        for p in posts where p.status != .cancelled {
            let platforms = p.platforms.map(\.displayName).joined(separator: ", ")
            var description = "Status: \(p.status.rawValue)\\nPlatforms: \(escape(platforms))\\nVisibility: \(p.visibility.rawValue)"
            for r in p.results { description += "\\n\(r.platform.displayName): \(escape(r.url?.absoluteString ?? r.remoteID)) (\(escape(r.status)))" }
            for (platform, error) in p.errors.sorted(by: { $0.key < $1.key }) { description += "\\n\(platform) error: \(escape(error))" }
            lines += ["BEGIN:VEVENT",
                      "UID:\(p.id.uuidString.lowercased())@clipper",
                      "DTSTAMP:\(stamp(now))",
                      "DTSTART:\(stamp(p.scheduledAt))",
                      "DTEND:\(stamp(p.scheduledAt.addingTimeInterval(duration)))",
                      "SUMMARY:\(escape(statusIcon(p.status) + " " + p.title)) (\(escape(platforms)))",
                      "DESCRIPTION:\(description)",
                      "CATEGORIES:Clipper",
                      "END:VEVENT"]
        }
        lines.append("END:VCALENDAR")
        return lines.map(fold).joined(separator: "\r\n") + "\r\n"
    }

    static func statusIcon(_ s: ScheduledPost.Status) -> String {
        switch s {
        case .scheduled: "🗓"
        case .exporting, .uploading: "⏳"
        case .posted: "✅"
        case .partial: "◐"
        case .failed: "⚠️"
        case .cancelled: "✕"
        }
    }

    /// UTC "basic" format, e.g. 20261013T140000Z.
    static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: d)
    }

    /// TEXT escaping (RFC 5545 §3.3.11): backslash, semicolon, comma, newline.
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Lines longer than 75 octets are folded with CRLF + space, never splitting a UTF-8 character.
    static func fold(_ line: String) -> String {
        var out = "", current = 0
        for ch in line {
            let n = String(ch).utf8.count
            if current + n > 75 { out += "\r\n "; current = 1 }
            out.append(ch); current += n
        }
        return out
    }
}
