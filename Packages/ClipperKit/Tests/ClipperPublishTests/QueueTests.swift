import Foundation
import Testing
@testable import ClipperPublish

@Suite struct PublishQueueTests {
    func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("clipper-queue-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func dueOrderingAndUpdates() throws {
        let q = PublishQueue(directory: tempDir())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let later = ScheduledPost(projectID: UUID(), platforms: [.youtube], title: "Later", scheduledAt: now.addingTimeInterval(3600))
        let soon = ScheduledPost(projectID: UUID(), platforms: [.youtube, .tiktok], title: "Soon", scheduledAt: now.addingTimeInterval(-60))
        let older = ScheduledPost(projectID: UUID(), platforms: [.tiktok], title: "Older", scheduledAt: now.addingTimeInterval(-600))
        try q.add(later); try q.add(soon); try q.add(older)
        #expect(try q.due(at: now).map(\.title) == ["Older", "Soon"])

        try q.update(soon.id) { p in
            p.results.append(PublishResult(platform: .youtube, remoteID: "abc", url: nil, status: "uploaded"))
            p.status = .partial
        }
        let updated = try q.posts().first { $0.id == soon.id }!
        #expect(updated.remainingPlatforms == [.tiktok])
        #expect(try q.due(at: now).contains { $0.id == soon.id })   // partial posts are retried
        try q.update(older.id) { $0.status = .posted }
        #expect(try q.due(at: now).map(\.title) == ["Soon"])
        try q.remove(later.id)
        #expect(try q.posts().count == 2)
        // A second queue on the same file (CLI vs app) sees the same state.
        #expect(try PublishQueue(directory: q.url.deletingLastPathComponent()).posts().count == 2)
    }

    @Test func requestDescriptionKeepsCredits() {
        let r = PublishRequest(file: URL(fileURLWithPath: "/tmp/x.mp4"), title: "t", description: "Hello",
                               attributions: ["\"Song\" Kevin MacLeod (incompetech.com)"])
        #expect(r.fullDescription.hasSuffix("Music:\n\"Song\" Kevin MacLeod (incompetech.com)"))
    }
}

@Suite struct CalendarTests {
    @Test func icsIsValidAndFolded() {
        var p = ScheduledPost(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, projectID: UUID(),
                              platforms: [.youtube, .tiktok], title: "Why nobody uses this, really; a very long title that goes on and on for folding",
                              scheduledAt: Date(timeIntervalSince1970: 1_791_000_000))
        p.results = [PublishResult(platform: .youtube, remoteID: "vid", url: URL(string: "https://youtu.be/vid"), status: "private")]
        let ics = PublishCalendar.ics([p], now: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(ics.hasPrefix("BEGIN:VCALENDAR\r\nVERSION:2.0\r\n"))
        #expect(ics.hasSuffix("END:VCALENDAR\r\n"))
        #expect(ics.contains("UID:11111111-2222-3333-4444-555555555555@clipper"))
        #expect(ics.contains("DTSTART:20261003T"))
        #expect(ics.contains("\\, really\\; a very"))           // escaped
        for line in ics.components(separatedBy: "\r\n") { #expect(line.utf8.count <= 75) }
        #expect(ics.contains("https://youtu.be/vid"))
    }

    @Test func foldingNeverSplitsCharacters() {
        let line = "SUMMARY:" + String(repeating: "é🎬", count: 40)
        let folded = PublishCalendar.fold(line)
        #expect(folded.replacingOccurrences(of: "\r\n ", with: "") == line)
        for part in folded.components(separatedBy: "\r\n") { #expect(part.utf8.count <= 75) }
    }
}
