import ClipperCore
import Foundation
import GRDB

extension Library {
    /// Emits the current assets immediately, then again after every change made through this `Library` instance.
    ///
    /// GRDB observes writes made through its own connection pool only: changes written by another process (e.g. the
    /// CLI while the app is open) are not seen until this instance writes again. Re-query after such work completes.
    public func observeAssets() -> AsyncThrowingStream<[MediaAsset], Error> {
        observe { [self] db in try AssetRow.ordered.fetchAll(db).map { try $0.asset(in: self) } }
    }

    /// Project summaries, most recently modified first. Same cross-process caveat as `observeAssets()`.
    public func observeProjects() -> AsyncThrowingStream<[ProjectSummary], Error> {
        observe { db in try ProjectRow.newestFirst.fetchAll(db).map(\.summary) }
    }

    /// Jobs (optionally filtered by status) in creation order. Same cross-process caveat as `observeAssets()`.
    public func observeJobs(status: JobStatus? = nil) -> AsyncThrowingStream<[JobRecord], Error> {
        observe { db in try JobRow.request(status: status).fetchAll(db).map(\.record) }
    }

    private func observe<T: Sendable & Equatable>(_ fetch: @escaping @Sendable (Database) throws -> T) -> AsyncThrowingStream<T, Error> {
        let values = ValueObservation.tracking(fetch).removeDuplicates().values(in: dbPool)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await value in values { continuation.yield(value) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
