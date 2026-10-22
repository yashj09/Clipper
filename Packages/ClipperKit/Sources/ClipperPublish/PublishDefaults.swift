import ClipperCore
import Foundation

/// The title, description and tags a timeline suggests for publishing: its name, the brief's description, a YouTube
/// chapter list from its "Chapter: " markers, and the brief's hashtags.
public enum PublishDefaults {
    public static let chapterMarkerPrefix = "Chapter: "
    /// YouTube ignores a chapter list with fewer than 3 chapters or one shorter than 10 s. An added Intro doesn't count
    /// toward the 3: two chapters and a filler intro aren't worth a list.
    static let minChapters = 3
    static let minChapterSeconds = 10.0

    public static func make(timeline: Timeline) -> (title: String, description: String, tags: [String]) {
        let tags = (timeline.metadata?.hashtags ?? []).map(hashtag).filter { !$0.isEmpty }
        let text = timeline.metadata?.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let chapters = chapterLines(timeline.markers, duration: timeline.duration.seconds).joined(separator: "\n")
        let hashtags = tags.map { "#" + $0 }.joined(separator: " ")
        let description = [text, chapters, hashtags].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return (timeline.name, description, tags)
    }

    /// "0:00 Intro", "1:05 Setup", … in time order, or none when YouTube would reject the list. A first chapter within
    /// the first 10 s is moved to 0:00 (an intro that short couldn't be its own chapter); a later one gets an Intro
    /// before it. A chapter that would run under 10 s is folded into the one before it (or dropped, at the end).
    static func chapterLines(_ markers: [Marker], duration: Double) -> [String] {
        var chapters = markers.filter { $0.name.hasPrefix(chapterMarkerPrefix) }.sorted { $0.time < $1.time }.map {
            (start: $0.time.seconds, title: String($0.name.dropFirst(chapterMarkerPrefix.count)).trimmingCharacters(in: .whitespaces))
        }
        guard !chapters.isEmpty else { return [] }
        if chapters[0].start < minChapterSeconds { chapters[0].start = 0 } else { chapters.insert((0, "Intro"), at: 0) }
        var kept: [(start: Double, title: String)] = []
        for chapter in chapters where chapter.start - (kept.last?.start ?? -minChapterSeconds) >= minChapterSeconds { kept.append(chapter) }
        if let last = kept.last, duration - last.start < minChapterSeconds { kept.removeLast() }
        guard kept.count >= minChapters else { return [] }
        return kept.map { "\(timestamp($0.start)) \($0.title.isEmpty ? "Chapter" : $0.title)" }
    }

    /// "0:00", "12:34", "1:02:03".
    static func timestamp(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        let (h, m, sec) = (s / 3600, s / 60 % 60, s % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func hashtag(_ raw: String) -> String {
        raw.filter { !$0.isWhitespace && $0 != "#" }
    }
}
