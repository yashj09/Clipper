import Foundation

/// Reel limits from Meta's "Reel Specifications" (IG User Media reference, verified Oct 2026):
/// MOV/MP4, 3 s – 15 min, ≤ 300 MB, ≤ 1920 px wide, aspect ratio 0.01:1 – 10:1 (9:16 recommended),
/// HEVC/H.264 + AAC ≤ 48 kHz, 23–60 fps, ≤ 25 Mbps. Caption ≤ 2,200 characters, ≤ 30 hashtags, ≤ 20 @mentions.
/// https://developers.facebook.com/docs/instagram-platform/instagram-graph-api/reference/ig-user/media
public enum InstagramReels {
    public static let minDuration: Double = 3
    public static let maxDuration: Double = 15 * 60
    /// "300MB maximum" — counted in decimal megabytes to stay on the safe side.
    public static let maxFileSize: Int64 = 300 * 1_000_000
    public static let maxWidth = 1920
    public static let aspectRange: ClosedRange<Double> = 0.01...10
    public static let containers: Set<String> = ["mp4", "mov"]
    public static let maxCaptionLength = 2200
    public static let maxHashtags = 30
    public static let maxMentions = 20

    /// What the publisher needs to know about the file (display size, i.e. after rotation).
    public struct VideoFacts: Sendable, Equatable {
        public var duration: Double
        public var width: Int
        public var height: Int
        public init(duration: Double, width: Int, height: Int) {
            self.duration = duration; self.width = width; self.height = height
        }
    }

    /// Problems that block publishing (empty = OK) and notes worth surfacing.
    public static func check(fileExtension: String, fileSize: Int64, facts: VideoFacts?, visibility: Visibility)
        -> (problems: [String], notes: [String]) {
        var problems: [String] = []
        var notes: [String] = []
        if visibility != .public {
            problems.append("Instagram Reels are always public; set visibility to public to publish to Instagram")
        }
        if !containers.contains(fileExtension.lowercased()) {
            problems.append("container must be MP4 or MOV (got .\(fileExtension))")
        }
        if fileSize > maxFileSize {
            problems.append("file is \(fileSize / 1_000_000) MB; Reels allow at most 300 MB — export at a lower bitrate")
        }
        if let facts {
            if facts.duration < minDuration {
                problems.append(String(format: "video is %.1f s; Reels must be at least 3 s", facts.duration))
            } else if facts.duration > maxDuration {
                problems.append(String(format: "video is %.0f s; Reels published through the API can be at most 15 min", facts.duration))
            }
            if facts.width > maxWidth {
                problems.append("video is \(facts.width) px wide; Reels allow at most \(maxWidth) px")
            }
            if facts.width > 0, facts.height > 0 {
                let ratio = Double(facts.width) / Double(facts.height)
                if !aspectRange.contains(ratio) {
                    problems.append("aspect ratio \(facts.width):\(facts.height) is outside 0.01:1 – 10:1")
                } else if abs(ratio - 9.0 / 16.0) > 0.01 {
                    notes.append("aspect ratio \(facts.width):\(facts.height) is not the recommended 9:16")
                }
            } else {
                problems.append("could not read the video dimensions")
            }
        }
        return (problems, notes)
    }
}

/// Caption = title, description, music credits, hashtags (from tags) — fitted into 2,200 characters.
///
/// Credits are never dropped (CC-BY). When too long, the description is shortened first (with "…"), then the
/// hashtag line is dropped, then the title is shortened. Lengths are counted in UTF-16 code units, which is never
/// fewer than the user-visible character count.
public enum InstagramCaption {
    public static func build(title: String, description: String, attributions: [String], tags: [String],
                             maxLength: Int = InstagramReels.maxCaptionLength) throws -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let credits = attributions.isEmpty ? "" : "Music:\n" + attributions.joined(separator: "\n")

        var problems: [String] = []
        let existingTags = hashtagCount(title) + hashtagCount(description)
        if existingTags > InstagramReels.maxHashtags {
            problems.append("title and description contain \(existingTags) hashtags; Instagram allows \(InstagramReels.maxHashtags)")
        }
        let mentions = mentionCount(title) + mentionCount(description)
        if mentions > InstagramReels.maxMentions {
            problems.append("caption mentions \(mentions) accounts; Instagram allows \(InstagramReels.maxMentions)")
        }
        if length(credits) > maxLength {
            problems.append("music credits alone exceed \(maxLength) characters")
        }
        guard problems.isEmpty else { throw InstagramError.validation(problems) }

        let alreadyTagged = Set(hashtagsIn(title + "\n" + description).map { $0.lowercased() })
        let newTags = hashtags(from: tags).filter { !alreadyTagged.contains($0.lowercased()) }
        var hashtagLine = newTags.prefix(max(0, InstagramReels.maxHashtags - existingTags)).joined(separator: " ")
        var titlePart = title

        func assemble() -> String {
            [titlePart, description, credits, hashtagLine].filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        var caption = assemble()
        if length(caption) > maxLength, !description.isEmpty {
            let others = [titlePart, credits, hashtagLine].filter { !$0.isEmpty }
            let budget = maxLength - length(others.joined(separator: "\n\n")) - (others.isEmpty ? 0 : 2)
            description = budget >= 2 ? truncate(description, to: budget) : ""
            caption = assemble()
        }
        if length(caption) > maxLength, !hashtagLine.isEmpty {
            hashtagLine = ""
            caption = assemble()
        }
        if length(caption) > maxLength, !titlePart.isEmpty {
            let others = [description, credits].filter { !$0.isEmpty }
            let budget = maxLength - length(others.joined(separator: "\n\n")) - (others.isEmpty ? 0 : 2)
            titlePart = budget >= 2 ? truncate(titlePart, to: budget) : ""
            caption = assemble()
        }
        return caption
    }

    public static func build(_ request: PublishRequest) throws -> String {
        try build(title: request.title, description: request.description, attributions: request.attributions, tags: request.tags)
    }

    /// Tags → `#hashtags`: letters, digits and underscores only, de-duplicated case-insensitively.
    public static func hashtags(from tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.compactMap { tag in
            let cleaned = String(String.UnicodeScalarView(tag.unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0) || $0 == "_"
            }))
            guard !cleaned.isEmpty, seen.insert(cleaned.lowercased()).inserted else { return nil }
            return "#" + cleaned
        }
    }

    static func hashtagsIn(_ text: String) -> [String] {
        text.matches(of: /#[\p{L}\p{N}_]+/).map { String($0.output) }
    }

    static func hashtagCount(_ text: String) -> Int { hashtagsIn(text).count }
    static func mentionCount(_ text: String) -> Int { text.matches(of: /(?:^|[^\w@])@[A-Za-z0-9._]+/).count }

    static func length(_ s: String) -> Int { s.utf16.count }

    /// Shortens on a character boundary to at most `limit` UTF-16 units, ending in "…".
    static func truncate(_ s: String, to limit: Int) -> String {
        guard length(s) > limit else { return s }
        var out = ""
        var used = 0
        for ch in s {
            let n = String(ch).utf16.count
            if used + n > limit - 1 { break }
            out.append(ch); used += n
        }
        while let last = out.last, last.isWhitespace { out.removeLast() }
        return out + "…"
    }
}
