import ClipperCore
import Foundation
import Testing
@testable import ClipperPublish

@Suite struct PublishDefaultsTests {
    func timeline(seconds: Double = 130, chapters: [(Double, String)], metadata: TimelineMetadata? = nil) -> Timeline {
        let clip = Item(range: TimeRange(seconds: 0, seconds), content: .solid(RGBA(0, 0, 0, 1)))
        let markers = chapters.map { Marker(time: RationalTime(seconds: $0.0), name: "Chapter: \($0.1)") }
            + [Marker(time: RationalTime(seconds: 5), name: "Retake")]
        return Timeline(name: "Three tips", canvas: .landscape1080, tracks: [Track(kind: .video, items: [clip])],
                        markers: markers.sorted { $0.time < $1.time }, metadata: metadata)
    }

    @Test func descriptionHasTheBriefChaptersAndHashtags() {
        let tl = timeline(chapters: [(15, "Setup"), (40, "Build"), (75.6, "Ship"), (100, "Wrap up")],
                          metadata: TimelineMetadata(description: "How I edit on a Mac.", hashtags: ["editing", "#mac", "video tips"]))
        let defaults = PublishDefaults.make(timeline: tl)
        #expect(defaults.title == "Three tips")
        #expect(defaults.description == """
            How I edit on a Mac.

            0:00 Intro
            0:15 Setup
            0:40 Build
            1:15 Ship
            1:40 Wrap up

            #editing #mac #videotips
            """)
        #expect(defaults.tags == ["editing", "mac", "videotips"])
        // Credits still follow, after everything else.
        let request = PublishRequest(file: URL(fileURLWithPath: "/tmp/v.mp4"), title: defaults.title, description: defaults.description,
                                     attributions: ["Song by Artist (CC BY 4.0)"])
        #expect(request.fullDescription.hasSuffix("#editing #mac #videotips\n\nMusic:\nSong by Artist (CC BY 4.0)"))
    }

    @Test func aFirstChapterNearTheStartBecomesZero() {
        let lines = PublishDefaults.chapterLines(timeline(chapters: [(3, "Hello"), (20, "Two"), (45, "Three")]).markers, duration: 60)
        #expect(lines == ["0:00 Hello", "0:20 Two", "0:45 Three"])
    }

    @Test func noChapterListWhenYouTubeWouldRejectIt() {
        let two = PublishDefaults.make(timeline: timeline(chapters: [(0, "Start"), (30, "End")]))
        #expect(two.description.isEmpty)
        // Under 10 s apart, or a last chapter under 10 s long.
        #expect(PublishDefaults.chapterLines(timeline(chapters: [(0, "A"), (30, "B"), (35, "C")]).markers, duration: 60).isEmpty)
        #expect(PublishDefaults.chapterLines(timeline(chapters: [(0, "A"), (30, "B"), (55, "C")]).markers, duration: 60).isEmpty)
        // No brief: chapters alone.
        let bare = PublishDefaults.make(timeline: timeline(chapters: [(0, "A"), (30, "B"), (60, "C")]))
        #expect(bare.description == "0:00 A\n0:30 B\n1:00 C" && bare.tags.isEmpty)
        #expect(PublishDefaults.timestamp(3723.9) == "1:02:03")
    }

    @Test func youTubeCapCutsProseBeforeChaptersAndNeverCredits() throws {
        let prose = String(repeating: "Long words here. ", count: 400)
        let tl = timeline(chapters: [(15, "Setup"), (40, "Build"), (75, "Ship"), (100, "Wrap up")],
                          metadata: TimelineMetadata(description: prose, hashtags: ["editing"]))
        let defaults = PublishDefaults.make(timeline: tl)
        let request = PublishRequest(file: URL(fileURLWithPath: "/tmp/v.mp4"), title: defaults.title, description: defaults.description,
                                     attributions: ["Song by Artist (CC BY 4.0)"])
        #expect(request.fullDescription.utf8.count > 5000)
        let sent = YouTubePublisher.description(for: request)
        #expect(sent.utf8.count <= 5000)
        #expect(sent.hasPrefix("Long words here."))
        #expect(sent.contains("…\n\n0:00 Intro\n0:15 Setup\n0:40 Build\n1:15 Ship\n1:40 Wrap up\n\n#editing\n\nMusic:\n"))
        #expect(sent.hasSuffix("Music:\nSong by Artist (CC BY 4.0)"))

        // With no room for prose at all, the hashtags go next, then chapters from the end; credits stay.
        let credits = (1...68).map { "Track \($0) by Someone Quite Long (CC BY 4.0), https://example.com/music/\($0)" }
        let crowded = PublishRequest(file: request.file, title: "t", description: defaults.description, attributions: credits)
        let squeezed = YouTubePublisher.description(for: crowded)
        #expect(squeezed.utf8.count <= 5000)
        #expect(squeezed.hasSuffix(credits.joined(separator: "\n")))
        #expect(squeezed.hasPrefix("0:00 Intro\n0:15 Setup\n0:40 Build\n1:15 Ship\n\nMusic:\n"))
    }
}
