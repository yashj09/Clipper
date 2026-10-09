import Dispatch

/// Task executor for analysis work that blocks a thread in synchronous decoder calls
/// (`AVAssetReaderOutput.copyNextSampleBuffer`, which can wait tens of milliseconds per buffer).
///
/// Running such loops on Swift's cooperative pool is a deadlock hazard: the pool has one thread per core, and once every
/// thread is parked in a decoder wait, AVFoundation's own async work (which needs the pool) can no longer run — observed
/// with a dozen concurrent analyzers. Analyzers therefore run their decode loops under
/// `withTaskExecutorPreference(DecodeExecutor.shared)`; jobs go to a concurrent GCD queue, which adds threads when
/// existing ones block.
final class DecodeExecutor: TaskExecutor {
    static let shared = DecodeExecutor()

    private let queue = DispatchQueue(label: "clipper.analysis.decode", qos: .userInitiated, attributes: .concurrent)

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}

/// Runs `operation` (and the nonisolated async code it calls) on `DecodeExecutor`.
func offCooperativePool<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
    try await withTaskExecutorPreference(DecodeExecutor.shared, isolation: nil, operation: operation)
}
