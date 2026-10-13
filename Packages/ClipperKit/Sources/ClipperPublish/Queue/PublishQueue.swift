import ClipperCore
import Foundation

/// A post planned for one or more platforms: which timeline to export, metadata, when, and what happened.
public struct ScheduledPost: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable { case scheduled, exporting, uploading, posted, partial, failed, cancelled
        /// A run owns the post (see `PublishQueue.claim`).
        public var isRunning: Bool { self == .exporting || self == .uploading }
    }

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
    /// When the queue entry last changed (bookkeeping; never derived from `scheduledAt`).
    public var updated: Date
    /// Process running the post while it is exporting/uploading, so a run interrupted by a crash or quit can be told
    /// apart from one still in progress in another process (app vs. LaunchAgent).
    public var runnerPID: Int32?

    public init(id: UUID = UUID(), projectID: UUID, timelineIndex: Int = 0, platforms: [Platform], title: String,
                description: String = "", tags: [String] = [], visibility: Visibility = .private, scheduledAt: Date,
                presetID: String = "shorts-1080x1920", created: Date = Date()) {
        self.id = id; self.projectID = projectID; self.timelineIndex = timelineIndex; self.platforms = platforms
        self.title = title; self.description = description; self.tags = tags; self.visibility = visibility
        self.scheduledAt = scheduledAt; self.presetID = presetID; self.status = .scheduled; self.results = []
        self.errors = [:]; self.exportedFile = nil; self.updated = created; self.runnerPID = nil
    }

    /// Platforms still to do (not yet posted successfully).
    public var remainingPlatforms: [Platform] { platforms.filter { p in !results.contains { $0.platform == p } } }

    /// Reasons the post can't be published as requested (empty = OK). Checked when scheduling, so a combination a
    /// platform would reject (or silently change) never enters the queue.
    public var problems: [String] {
        var out: [String] = []
        if platforms.isEmpty { out.append("Choose at least one platform.") }
        if platforms.contains(.instagram), visibility != .public {
            out.append("Instagram Reels are always public: set the visibility to public, or leave Instagram out.")
        }
        return out
    }
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

    /// Statuses a run may start from: due posts, and failed ones when the user explicitly retries.
    public static let runnableStatuses: Set<ScheduledPost.Status> = [.scheduled, .partial, .failed]

    /// Atomically takes ownership of a post for this process: under the queue lock, moves it from one of `from` to
    /// `.exporting` and returns the claimed (current) post. Returns nil when it isn't claimable — already running in
    /// the app or the LaunchAgent, posted, cancelled or removed — so two runners never export and upload it twice.
    public func claim(_ id: UUID, from: Set<ScheduledPost.Status> = PublishQueue.runnableStatuses,
                      pid: Int32 = getpid(), now: Date = Date()) throws -> ScheduledPost? {
        try mutate { posts in
            guard let i = posts.firstIndex(where: { $0.id == id }), from.contains(posts[i].status),
                  !posts[i].status.isRunning else { return nil }
            posts[i].status = .exporting
            posts[i].runnerPID = pid
            posts[i].updated = now
            return posts[i]
        }
    }

    /// Puts posts whose run was interrupted (the app or CLI crashed or quit mid-export/upload) back in the queue, so
    /// they aren't shown as in progress forever and are retried by the next run. A run counts as interrupted when its
    /// process is gone, when it has no recorded process and hasn't changed for `timeout`, or after `maxRunTime`
    /// regardless (guards against a reused process id). Returns the requeued posts.
    @discardableResult
    public func recoverInterrupted(now: Date = Date(), timeout: TimeInterval = 2 * 3600, maxRunTime: TimeInterval = 12 * 3600,
                                   isAlive: (Int32) -> Bool = PublishQueue.processIsAlive) throws -> [ScheduledPost] {
        try mutate { posts in
            var recovered: [ScheduledPost] = []
            for i in posts.indices where posts[i].status.isRunning {
                let age = now.timeIntervalSince(posts[i].updated)
                let stale = age > maxRunTime || (posts[i].runnerPID.map { !isAlive($0) } ?? (age > timeout))
                guard stale else { continue }
                posts[i].errors["interrupted"] = "The run was interrupted while \(posts[i].status.rawValue) (Clipper quit or crashed); it will be retried. Check the platform for a partial upload."
                posts[i].status = posts[i].results.isEmpty ? .scheduled : .partial
                posts[i].runnerPID = nil
                posts[i].updated = now
                recovered.append(posts[i])
            }
            return recovered
        }
    }

    /// True while a process with this id exists (EPERM: it exists but belongs to someone else).
    public static func processIsAlive(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    // MARK: Storage

    private func mutate<R>(_ body: (inout [ScheduledPost]) throws -> R) throws -> R {
        try lock.withLock {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Cross-process exclusion (app + CLI): an advisory lock on a sibling file.
            let lockPath = url.deletingLastPathComponent().appendingPathComponent(".queue.lock").path
            let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
            guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
            defer { flock(fd, LOCK_UN); close(fd) }
            flock(fd, LOCK_EX)
            var posts = try load()
            let result = try body(&posts)
            try ClipperJSON.encode(posts.sorted { $0.scheduledAt < $1.scheduledAt }).write(to: url, options: .atomic)
            return result
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
