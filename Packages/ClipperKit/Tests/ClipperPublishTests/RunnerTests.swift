import ClipperCore
import Foundation
import Testing
@testable import ClipperPublish

/// Records what it was asked to publish; optionally fails or runs a side effect first.
final class FakePublisher: Publisher, Sendable {
    let platform: Platform
    let requests = Box<[PublishRequest]>([])
    let failure: String?
    let sideEffect: (@Sendable () throws -> Void)?

    init(_ platform: Platform, failure: String? = nil, sideEffect: (@Sendable () throws -> Void)? = nil) {
        self.platform = platform; self.failure = failure; self.sideEffect = sideEffect
    }

    func isConnected() async -> Bool { true }

    func publish(_ request: PublishRequest, progress: (@Sendable (UploadProgress) -> Void)?) async throws -> PublishResult {
        requests.update { $0.append(request) }
        try sideEffect?()
        if let failure { throw PublishError.publishFailed(platform: platform, reason: failure) }
        return PublishResult(platform: platform, remoteID: "\(platform.rawValue)-\(request.title)", url: nil, status: "ok")
    }
}

@Suite struct PublishRunnerTests {
    func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("clipper-runner-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func captionTrack(_ language: String?, hidden: Bool, text: String) -> Track {
        Track(kind: .caption, items: [Item(range: TimeRange(seconds: 0, 1),
                                           content: .caption(CaptionContent(words: [.init(text: text, start: .zero, end: RationalTime(seconds: 1))], style: "c")))],
              hidden: hidden, language: language)
    }

    /// A runner whose "export" writes a dummy video plus the SRT sidecars the real exporter would write.
    func makeRunner(_ queue: PublishQueue, timeline: Timeline, publishers: [FakePublisher], exports: Box<Int> = Box(0),
                    exportDelay: Duration = .zero, exportError: String? = nil) -> PublishRunner {
        PublishRunner(queue: queue, loadTimeline: { _ in timeline }, export: { timeline, _, url in
            exports.update { $0 += 1 }
            try await Task.sleep(for: exportDelay)
            if let exportError { throw PublishError.invalidFile(exportError) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("video".utf8).write(to: url)
            let name = url.deletingPathExtension().lastPathComponent
            for sidecar in Subtitles.sidecars(timeline, formats: [.srt]) {
                try sidecar.contents.write(to: url.deletingLastPathComponent().appendingPathComponent("\(name).\(sidecar.suffix)"),
                                           atomically: true, encoding: .utf8)
            }
            return url
        }, publisher: { platform in
            guard let p = publishers.first(where: { $0.platform == platform }) else { throw PublishError.unsupportedPlatform(platform) }
            return p
        })
    }

    @Test func runPublishesExactlyTheGivenPost() async throws {
        let q = PublishQueue(directory: tempDir())
        // A post scheduled for next week used to win `publish now`'s "latest updated" pick (updated = scheduledAt).
        let nextWeek = ScheduledPost(projectID: UUID(), platforms: [.youtube], title: "A", scheduledAt: Date().addingTimeInterval(7 * 86_400))
        let now = ScheduledPost(projectID: UUID(), platforms: [.youtube], title: "B", scheduledAt: Date())
        #expect(nextWeek.updated <= Date())
        try q.add(nextWeek); try q.add(now)
        let youtube = FakePublisher(.youtube)
        let done = try #require(try await makeRunner(q, timeline: Timeline(name: "B", canvas: .vertical1080), publishers: [youtube]).run(now.id))
        #expect(youtube.requests.value.map(\.title) == ["B"])
        #expect(done.status == .posted && done.runnerPID == nil)
        #expect(try q.posts().first { $0.id == nextWeek.id }?.status == .scheduled)
    }

    @Test func concurrentRunnersPublishOnce() async throws {
        let dir = tempDir()
        let post = ScheduledPost(projectID: UUID(), platforms: [.youtube], title: "Once", scheduledAt: Date())
        try PublishQueue(directory: dir).add(post)
        let youtube = FakePublisher(.youtube), exports = Box(0)
        // The app and the LaunchAgent each have their own queue object on the same file.
        let app = makeRunner(PublishQueue(directory: dir), timeline: Timeline(name: "t", canvas: .vertical1080), publishers: [youtube], exports: exports,
                             exportDelay: .milliseconds(150))
        let agent = makeRunner(PublishQueue(directory: dir), timeline: Timeline(name: "t", canvas: .vertical1080), publishers: [youtube], exports: exports,
                               exportDelay: .milliseconds(150))
        async let a = app.run(post.id)
        async let b = agent.runDue()
        let (ranByApp, ranByAgent) = try await (a, b)
        #expect(exports.value == 1)
        #expect(youtube.requests.value.count == 1)
        #expect((ranByApp != nil) != !ranByAgent.isEmpty)   // exactly one of them ran it
        #expect(try PublishQueue(directory: dir).posts().first?.status == .posted)
    }

    @Test func claimIsExclusiveAcrossQueueInstances() async throws {
        let dir = tempDir()
        let post = ScheduledPost(projectID: UUID(), platforms: [.tiktok], title: "x", scheduledAt: Date())
        try PublishQueue(directory: dir).add(post)
        let queues = [PublishQueue(directory: dir), PublishQueue(directory: dir)]
        let claims = try await withThrowingTaskGroup(of: Bool.self) { group in
            for i in 0..<20 { group.addTask { try queues[i % 2].claim(post.id) != nil } }
            return try await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(claims == 1)
        let claimed = try #require(try queues[0].posts().first)
        #expect(claimed.status == .exporting && claimed.runnerPID == getpid())
        // Finished or cancelled posts can't be claimed; failed ones only when explicitly retried.
        try queues[0].update(post.id) { $0.status = .failed }
        #expect(try queues[0].claim(post.id, from: [.scheduled, .partial]) == nil)
        #expect(try queues[0].claim(post.id) != nil)
        try queues[0].update(post.id) { $0.status = .cancelled }
        #expect(try queues[0].claim(post.id) == nil)
    }

    @Test func interruptedRunsAreRequeued() throws {
        let q = PublishQueue(directory: tempDir())
        let dead = ScheduledPost(projectID: UUID(), platforms: [.youtube], title: "dead", scheduledAt: Date())
        let deadPartial = ScheduledPost(projectID: UUID(), platforms: [.youtube, .tiktok], title: "dead-partial", scheduledAt: Date())
        let alive = ScheduledPost(projectID: UUID(), platforms: [.youtube], title: "alive", scheduledAt: Date())
        let legacy = ScheduledPost(projectID: UUID(), platforms: [.youtube], title: "legacy", scheduledAt: Date())
        for p in [dead, deadPartial, alive, legacy] { try q.add(p) }
        try q.update(dead.id) { $0.status = .exporting; $0.runnerPID = 111 }
        try q.update(deadPartial.id) { p in
            p.status = .uploading; p.runnerPID = 111
            p.results = [PublishResult(platform: .youtube, remoteID: "v", url: nil, status: "ok")]
        }
        try q.update(alive.id) { $0.status = .uploading; $0.runnerPID = 222 }
        try q.update(legacy.id) { $0.status = .exporting }   // written before runs recorded their process

        let isAlive: (Int32) -> Bool = { $0 == 222 }
        #expect(try q.recoverInterrupted(isAlive: isAlive).map(\.title).sorted() == ["dead", "dead-partial"])
        var byTitle = Dictionary(uniqueKeysWithValues: try q.posts().map { ($0.title, $0) })
        #expect(byTitle["dead"]?.status == .scheduled && byTitle["dead"]?.runnerPID == nil)
        #expect(byTitle["dead"]?.errors["interrupted"] != nil)
        #expect(byTitle["dead-partial"]?.status == .partial)
        #expect(byTitle["alive"]?.status == .uploading)
        #expect(byTitle["legacy"]?.status == .exporting)
        // Three hours later the owner-less run is considered dead; a live owner keeps its post.
        try q.recoverInterrupted(now: Date().addingTimeInterval(3 * 3600), isAlive: isAlive)
        byTitle = Dictionary(uniqueKeysWithValues: try q.posts().map { ($0.title, $0) })
        #expect(byTitle["legacy"]?.status == .scheduled)
        #expect(byTitle["alive"]?.status == .uploading)
        #expect(PublishQueue.processIsAlive(getpid()))
    }

    @Test func runDueLeavesFailedAndRunningPostsAlone() async throws {
        let q = PublishQueue(directory: tempDir())
        let failed = ScheduledPost(projectID: UUID(), platforms: [.youtube], title: "failed", scheduledAt: Date().addingTimeInterval(-60))
        let running = ScheduledPost(projectID: UUID(), platforms: [.youtube], title: "running", scheduledAt: Date().addingTimeInterval(-60))
        let due = ScheduledPost(projectID: UUID(), platforms: [.youtube], title: "due", scheduledAt: Date().addingTimeInterval(-60))
        for p in [failed, running, due] { try q.add(p) }
        try q.update(failed.id) { $0.status = .failed }
        try q.update(running.id) { $0.status = .uploading; $0.runnerPID = getpid() }
        let youtube = FakePublisher(.youtube)
        let done = try await makeRunner(q, timeline: Timeline(name: "t", canvas: .vertical1080), publishers: [youtube]).runDue()
        #expect(done.map(\.title) == ["due"])
        #expect(youtube.requests.value.map(\.title) == ["due"])
    }

    @Test func instagramVisibilityIsPassedThroughAndValidated() async throws {
        let q = PublishQueue(directory: tempDir())
        let post = ScheduledPost(projectID: UUID(), platforms: [.instagram], title: "reel", visibility: .private, scheduledAt: Date())
        #expect(post.problems.contains { $0.contains("Instagram Reels are always public") })
        #expect(ScheduledPost(projectID: UUID(), platforms: [.instagram], title: "r", visibility: .public, scheduledAt: Date()).problems.isEmpty)
        #expect(!ScheduledPost(projectID: UUID(), platforms: [], title: "r", scheduledAt: Date()).problems.isEmpty)
        // A queued post (e.g. from an older version) is never silently made public; the publisher's own check decides.
        try q.add(post)
        let instagram = FakePublisher(.instagram)
        try await makeRunner(q, timeline: Timeline(name: "t", canvas: .vertical1080), publishers: [instagram]).run(post.id)
        #expect(instagram.requests.value.map(\.visibility) == [.private])
    }

    @Test func captionsAreLabelledWithTheirLanguageAndSentOnce() async throws {
        // Spanish-only captions are written as the plain "<name>.srt": they must be labelled "es", not "en".
        var spanish = Timeline(name: "clip", canvas: .vertical1080, styles: ["c": TextStyle()])
        spanish.tracks = [captionTrack("es", hidden: false, text: "Hola")]
        // Visible English + hidden Spanish: "<name>.srt" duplicates "<name>.en.srt" and is not sent.
        var both = Timeline(name: "clip", canvas: .vertical1080, styles: ["c": TextStyle()])
        both.tracks = [captionTrack("en", hidden: false, text: "Hello"), captionTrack("es", hidden: true, text: "Hola")]

        for (timeline, expected) in [(spanish, [("srt", "es")]), (both, [("en.srt", "en"), ("es.srt", "es")])] {
            let q = PublishQueue(directory: tempDir())
            let post = ScheduledPost(projectID: UUID(), platforms: [.youtube], title: "t", scheduledAt: Date())
            try q.add(post)
            // An unrelated file sharing the name prefix ("<id> clip2.srt") must not be picked up.
            let runner = makeRunner(q, timeline: timeline, publishers: [FakePublisher(.youtube)])
            let stray = runner.exportsDirectory.appendingPathComponent("\(post.id.uuidString.prefix(8)) clip2.srt")
            try FileManager.default.createDirectory(at: runner.exportsDirectory, withIntermediateDirectories: true)
            try Data("1\n00:00:00,000 --> 00:00:01,000\nother\n".utf8).write(to: stray)
            let youtube = FakePublisher(.youtube)
            try await makeRunner(q, timeline: timeline, publishers: [youtube]).run(post.id)
            let captions = try #require(youtube.requests.value.first).captions
            let video = "\(post.id.uuidString.prefix(8)) clip"
            #expect(captions.map(\.url.lastPathComponent) == expected.map { "\(video).\($0.0)" })
            #expect(captions.map(\.language) == expected.map(\.1))
        }
    }

    @Test func cancellingStopsBeforeTheNextPlatform() async throws {
        let q = PublishQueue(directory: tempDir())
        let post = ScheduledPost(projectID: UUID(), platforms: [.youtube, .tiktok], title: "t", scheduledAt: Date())
        try q.add(post)
        let youtube = FakePublisher(.youtube) { try q.update(post.id) { $0.status = .cancelled } }
        let tiktok = FakePublisher(.tiktok)
        let done = try #require(try await makeRunner(q, timeline: Timeline(name: "t", canvas: .vertical1080), publishers: [youtube, tiktok]).run(post.id))
        #expect(tiktok.requests.value.isEmpty)
        #expect(done.status == .cancelled && done.runnerPID == nil)
    }

    @Test func failuresAreRecordedOnThePost() async throws {
        let q = PublishQueue(directory: tempDir())
        let post = ScheduledPost(projectID: UUID(), platforms: [.youtube, .tiktok], title: "t", scheduledAt: Date())
        try q.add(post)
        let broken = try #require(try await makeRunner(q, timeline: Timeline(name: "t", canvas: .vertical1080), publishers: [], exportError: "disk full").run(post.id))
        #expect(broken.status == .failed)
        #expect(broken.errors["export"]?.contains("disk full") == true)

        // Retrying (explicit run) clears the export error; one platform failing leaves the post partial.
        let done = try #require(try await makeRunner(q, timeline: Timeline(name: "t", canvas: .vertical1080),
                                                     publishers: [FakePublisher(.youtube), FakePublisher(.tiktok, failure: "quota")]).run(post.id))
        #expect(done.status == .partial)
        #expect(done.errors["export"] == nil)
        #expect(done.errors["tiktok"]?.contains("quota") == true)
        #expect(done.remainingPlatforms == [.tiktok])
    }
}
