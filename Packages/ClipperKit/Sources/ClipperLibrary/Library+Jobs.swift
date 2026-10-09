import Foundation
import GRDB

public enum JobStatus: String, Codable, Sendable, CaseIterable {
    case queued, running, done, failed, cancelled

    public var isFinished: Bool { self == .done || self == .failed || self == .cancelled }
}

/// A persisted long-running job (analysis, export…), so the UI and CLI can list and resume work.
/// `payload` is opaque to the library (typically JSON the job's owner knows how to decode).
public struct JobRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: String
    public var title: String
    public var payload: Data?
    public var status: JobStatus
    public var progress: Double
    public var error: String?
    public var created: Date
    public var updated: Date

    public init(id: UUID = UUID(), kind: String, title: String, payload: Data? = nil, status: JobStatus = .queued,
                progress: Double = 0, error: String? = nil, created: Date = Date(), updated: Date? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.payload = payload; self.status = status
        self.progress = progress; self.error = error; self.created = created; self.updated = updated ?? created
    }
}

struct JobRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "job"
    var id: String
    var kind: String
    var title: String
    var payload: Data?
    var status: String
    var progress: Double
    var error: String?
    var created: Double
    var updated: Double

    init(_ j: JobRecord) {
        id = j.id.uuidString; kind = j.kind; title = j.title; payload = j.payload; status = j.status.rawValue
        progress = j.progress; error = j.error; created = j.created.dbValue; updated = j.updated.dbValue
    }

    var record: JobRecord {
        JobRecord(id: UUID(uuidString: id) ?? UUID(), kind: kind, title: title, payload: payload,
                  status: JobStatus(rawValue: status) ?? .failed, progress: progress, error: error,
                  created: Date(dbValue: created), updated: Date(dbValue: updated))
    }

    static func request(status: JobStatus?) -> QueryInterfaceRequest<JobRow> {
        var r = JobRow.order(Column("created"), Column("id"))
        if let status { r = r.filter(Column("status") == status.rawValue) }
        return r
    }
}

extension Library {
    /// Adds a new job. Throws if a job with the same id exists.
    public func enqueueJob(_ job: JobRecord) throws {
        try dbPool.write { db in try JobRow(job).insert(db) }
    }

    /// Replaces a job's state (status, progress, error, payload…) and stamps `updated` with now.
    @discardableResult
    public func updateJob(_ job: JobRecord) throws -> JobRecord {
        var job = job
        job.updated = Date()
        let row = JobRow(job)
        try dbPool.write { db in
            guard try JobRow.exists(db, key: row.id) else { throw LibraryError.jobNotFound(job.id) }
            try row.update(db)
        }
        return job
    }

    /// Jobs in creation order, optionally filtered by status.
    public func jobs(status: JobStatus? = nil) throws -> [JobRecord] {
        try dbPool.read { db in try JobRow.request(status: status).fetchAll(db) }.map(\.record)
    }

    public func job(_ id: UUID) throws -> JobRecord? {
        try dbPool.read { db in try JobRow.fetchOne(db, key: id.uuidString) }?.record
    }

    /// Deletes finished jobs (done, failed, cancelled) last updated before `date`.
    public func pruneFinishedJobs(before date: Date = .distantFuture) throws {
        let finished = JobStatus.allCases.filter(\.isFinished).map(\.rawValue)
        _ = try dbPool.write { db in
            try JobRow.filter(finished.contains(Column("status")) && Column("updated") < date.dbValue).deleteAll(db)
        }
    }
}
