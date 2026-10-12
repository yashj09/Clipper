import Foundation

/// Polls folders for new recordings and reports each once its size has been stable for two polls
/// (OBS and phone transfers write for a while). Files present when watching starts are ignored.
@MainActor
final class FolderWatcher {
    private var task: Task<Void, Never>?
    private var seen: Set<String> = []
    private var pending: [String: Int64] = [:]
    nonisolated static let extensions: Set<String> = ["mov", "mp4", "m4v", "mkv", "webm"]

    func start(folders: [URL], interval: Duration = .seconds(5), onNewFile: @escaping @MainActor (URL) async -> Void) {
        task?.cancel()
        seen = Set(folders.flatMap { Self.files(in: $0).map(\.path) })
        pending = [:]
        guard !folders.isEmpty else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                for url in folders.flatMap(Self.files(in:)) where !self.seen.contains(url.path) {
                    let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? -1
                    if size > 0, self.pending[url.path] == size {
                        self.seen.insert(url.path)
                        self.pending[url.path] = nil
                        await onNewFile(url)
                    } else {
                        self.pending[url.path] = size
                    }
                }
            }
        }
    }

    func stop() { task?.cancel(); task = nil }

    nonisolated static func files(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { extensions.contains($0.pathExtension.lowercased()) }
    }
}
