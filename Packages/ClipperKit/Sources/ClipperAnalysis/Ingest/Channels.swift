import ClipperCore
import Foundation

/// A bounded hand-off from a producer thread that may block (the shared ingest's decode loop) to an async consumer
/// (a transcriber, a Vision loop) pulling at its own pace. `send` blocks while `capacity` elements are queued, which
/// paces the decode to the slowest consumer and bounds memory; `next` suspends until an element arrives or the stream
/// ends. A consumer that stops early calls `close()`, after which `send` returns false immediately.
final class BoundedChannel<Element: Sendable>: @unchecked Sendable {
    private let condition = NSCondition()
    private var queue: [Element] = []
    private var head = 0
    private var finished = false
    private var closed = false
    private var failure: Error?
    private var waiter: CheckedContinuation<Element?, Error>?
    private let capacity: Int

    init(capacity: Int) { self.capacity = max(1, capacity) }

    /// Blocks while the queue is full. Returns false once the consumer has closed the channel.
    @discardableResult
    func send(_ element: Element) -> Bool {
        condition.lock()
        while queue.count - head >= capacity && !closed { condition.wait() }
        if closed { condition.unlock(); return false }
        if let waiter {
            self.waiter = nil
            condition.unlock()
            waiter.resume(returning: element)
            return true
        }
        queue.append(element)
        condition.unlock()
        return true
    }

    /// Ends the stream (with an error if the producer failed). Queued elements are still delivered first.
    func finish(throwing error: Error? = nil) {
        condition.lock()
        finished = true
        failure = error
        let waiter = queue.count - head == 0 ? self.waiter : nil
        if waiter != nil { self.waiter = nil }
        condition.broadcast()
        condition.unlock()
        if let error { waiter?.resume(throwing: error) } else { waiter?.resume(returning: nil) }
    }

    /// The consumer is done (finished, failed or cancelled): drops what is queued and unblocks the producer.
    func close() {
        condition.lock()
        closed = true
        queue.removeAll()
        head = 0
        let waiter = self.waiter
        self.waiter = nil
        condition.broadcast()
        condition.unlock()
        waiter?.resume(returning: nil)
    }

    /// The next element, or nil at the end of the stream.
    func next() async throws -> Element? {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Element?, Error>) in
            condition.lock()
            if head < queue.count {
                let element = queue[head]
                head += 1
                if head > 64 { queue.removeFirst(head); head = 0 }
                condition.broadcast()
                condition.unlock()
                c.resume(returning: element)
            } else if finished || closed {
                let error = closed ? nil : failure
                condition.unlock()
                if let error { c.resume(throwing: error) } else { c.resume(returning: nil) }
            } else {
                waiter = c
                condition.unlock()
            }
        }
    }
}

/// Mono Float32 PCM from the shared audio ingest to a `PCMStreamTranscriber` (~30 s of 16 kHz audio in flight at most).
public final class PCMChannel: @unchecked Sendable {
    private let chunks = BoundedChannel<[Float]>(capacity: 16)
    private let lock = NSLock()
    private var _startTime = 0.0

    public init() {}

    /// Source time (seconds) of the first sample. Set by the producer before it finishes the stream.
    public var startTime: Double {
        get { lock.withLock { _startTime } }
        set { lock.withLock { _startTime = newValue } }
    }

    /// Blocks while the transcriber is behind. Returns false once it has closed the channel.
    @discardableResult
    public func send(_ chunk: [Float]) -> Bool { chunk.isEmpty ? true : chunks.send(chunk) }
    /// Ends the stream (with an error if the decode failed).
    public func finish(throwing error: Error? = nil) { chunks.finish(throwing: error) }
    /// The transcriber is done: unblocks and stops the producer.
    public func close() { chunks.close() }
    /// The next chunk, or nil at the end of the stream.
    public func next() async throws -> [Float]? { try await chunks.next() }
}

/// A transcriber the shared ingest can feed with decoded audio instead of letting it decode the file again.
public protocol PCMStreamTranscriber: Transcriber {
    /// Sample rate of the mono Float32 PCM to send. The ingest converts with `Resampler` (never AVAssetReader).
    func streamSampleRate(locale: Locale) async throws -> Double
    /// Transcribes the channel's audio; word times are source seconds (the channel's `startTime` is added).
    func transcribe(pcm: PCMChannel, sampleRate: Double, locale: Locale) async throws -> Transcript
}
