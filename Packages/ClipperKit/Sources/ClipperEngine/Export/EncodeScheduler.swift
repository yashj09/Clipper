import Foundation

/// Serializes hardware video encoding. Phase 0 (S1) measured a foreground HEVC export dropping from ~210 fps to
/// 6 fps while another HEVC session ran on the M4 Pro's single media encoder, so exports, proxies and transcodes
/// all take turns here; foreground (user-visible) work jumps the queue and background work can poll
/// `shouldYield` to pause between chunks.
public actor EncodeScheduler {
    public static let shared = EncodeScheduler()
    public enum Priority: Sendable { case foreground, background }

    private var busy = false
    private var waiting: [(Priority, CheckedContinuation<Void, Never>)] = []

    public init() {}

    public var shouldYield: Bool { waiting.contains { $0.0 == .foreground } }

    public func run<T: Sendable>(_ priority: Priority, _ body: @Sendable () async throws -> T) async throws -> T {
        await acquire(priority)
        defer { release() }
        return try await body()
    }

    private func acquire(_ priority: Priority) async {
        if !busy { busy = true; return }
        await withCheckedContinuation { c in
            if priority == .foreground, let i = waiting.firstIndex(where: { $0.0 == .background }) {
                waiting.insert((priority, c), at: i)
            } else {
                waiting.append((priority, c))
            }
        }
    }

    private func release() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().1.resume() }
    }
}
