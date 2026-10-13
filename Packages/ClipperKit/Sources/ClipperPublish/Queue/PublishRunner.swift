import ClipperCore
import Foundation

/// Runs queued posts: claims each one, exports its timeline (once), uploads it to every remaining platform and records
/// the outcome in the queue. The app and the CLI (including the LaunchAgent's `run-due`) share it, so a post is claimed,
/// labelled and published the same way whoever runs it. Library access and rendering are injected.
public struct PublishRunner: Sendable {
    public typealias LoadTimeline = @Sendable (ScheduledPost) async throws -> Timeline
    /// Renders the timeline with the preset to the given file (writing caption sidecars beside it); returns the file.
    public typealias Export = @Sendable (Timeline, ExportPreset, URL) async throws -> URL
    public typealias MakePublisher = @Sendable (Platform) throws -> any Publisher

    /// Steps of a run, awaited in order (so a UI can't show a step after the run has finished).
    public enum Event: Sendable {
        case exporting(ScheduledPost)
        case uploading(ScheduledPost, Platform)
        case published(Platform, PublishResult)
        case failed(Platform, String)
    }

    public let queue: PublishQueue
    let loadTimeline: LoadTimeline
    let export: Export
    let publisher: MakePublisher
    let events: @Sendable (Event) async -> Void
    let progress: @Sendable (Platform, UploadProgress) -> Void

    public init(queue: PublishQueue, loadTimeline: @escaping LoadTimeline, export: @escaping Export,
                publisher: @escaping MakePublisher, events: @escaping @Sendable (Event) async -> Void = { _ in },
                progress: @escaping @Sendable (Platform, UploadProgress) -> Void = { _, _ in }) {
        self.queue = queue; self.loadTimeline = loadTimeline; self.export = export; self.publisher = publisher
        self.events = events; self.progress = progress
    }

    public var exportsDirectory: URL { queue.url.deletingLastPathComponent().appendingPathComponent("Exports", isDirectory: true) }

    /// Runs one post if this process can claim it (scheduled, partial or failed — an explicit retry). Returns the post
    /// as recorded afterwards, or nil when it wasn't runnable: already running in the app or the LaunchAgent, posted,
    /// cancelled or gone. Failures are recorded on the post, not thrown; only queue I/O errors throw.
    @discardableResult
    public func run(_ id: UUID, from statuses: Set<ScheduledPost.Status> = PublishQueue.runnableStatuses) async throws -> ScheduledPost? {
        guard let post = try queue.claim(id, from: statuses) else { return nil }
        try queue.update(id) { $0.errors["export"] = nil; $0.errors["interrupted"] = nil }
        do {
            try await execute(post)
        } catch {
            try queue.update(id) { $0.errors["export"] = Self.message(error) }
        }
        try queue.update(id) { p in
            if p.status.isRunning {
                p.status = p.remainingPlatforms.isEmpty ? .posted : (p.results.isEmpty ? .failed : .partial)
            }
            p.runnerPID = nil
        }
        return try queue.posts().first { $0.id == id }
    }

    /// Requeues interrupted runs, then runs every due post that this process can still claim (another runner may take
    /// some first). Returns the posts it ran.
    public func runDue(now: Date = Date()) async throws -> [ScheduledPost] {
        try queue.recoverInterrupted(now: now)
        var done: [ScheduledPost] = []
        for post in try queue.due(at: now) {
            // Only what is still due: a post another runner finished or failed meanwhile is not retried here.
            if let result = try await run(post.id, from: [.scheduled, .partial]) { done.append(result) }
        }
        return done
    }

    private func execute(_ post: ScheduledPost) async throws {
        let timeline = try await loadTimeline(post)
        var file = post.exportedFile
        if file == nil || !FileManager.default.fileExists(atPath: file!.path) {
            guard let preset = ExportPreset.named(post.presetID) else {
                throw PublishError.invalidFile("unknown export preset “\(post.presetID)”")
            }
            await events(.exporting(post))
            let name = "\(post.id.uuidString.prefix(8)) \(timeline.name)"
                .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            let destination = exportsDirectory.appendingPathComponent(name).appendingPathExtension(preset.container.fileExtension)
            let exported = try await export(timeline, preset, destination)
            file = exported
            try queue.update(post.id) { $0.exportedFile = exported }
        }
        guard let file else { return }
        try queue.update(post.id) { $0.status = .uploading }
        let captions = PublishRequest.captionFiles(besides: file, timeline: timeline)
        for platform in post.remainingPlatforms {
            // Stop between platforms if the user cancelled meanwhile (an upload in flight can't be taken back).
            if try queue.posts().first(where: { $0.id == post.id })?.status == .cancelled { return }
            await events(.uploading(post, platform))
            let request = PublishRequest(file: file, title: post.title, description: post.description, tags: post.tags,
                                         visibility: post.visibility, captions: captions, attributions: timeline.attributions)
            do {
                let progress = self.progress
                let result = try await publisher(platform).publish(request) { progress(platform, $0) }
                try queue.update(post.id) { $0.results.append(result); $0.errors[platform.rawValue] = nil }
                await events(.published(platform, result))
            } catch {
                let message = Self.message(error)
                try queue.update(post.id) { $0.errors[platform.rawValue] = message }
                await events(.failed(platform, message))
            }
        }
    }

    static func message(_ error: any Error) -> String { (error as? LocalizedError)?.errorDescription ?? "\(error)" }
}
