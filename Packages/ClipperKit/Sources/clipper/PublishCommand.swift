import ArgumentParser
import ClipperCore
import ClipperLibrary
import ClipperPublish
import Foundation

struct Publish: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Schedule and publish to YouTube, TikTok and Instagram (your own developer apps; nothing is posted until you ask).",
        subcommands: [Schedule.self, ListPosts.self, Calendar.self, Cancel.self])

    static func queue(_ s: Services) -> PublishQueue {
        PublishQueue(directory: s.library.url.appendingPathComponent("Publishing", isDirectory: true))
    }

    static func parseDate(_ text: String) throws -> Date {
        if text == "now" { return Date() }
        if text.hasPrefix("+"), let n = Double(text.dropFirst().dropLast()), let unit = text.last {
            let seconds: Double = switch unit { case "m": 60; case "h": 3600; case "d": 86_400; default: 0 }
            if seconds > 0 { return Date().addingTimeInterval(n * seconds) }
        }
        for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current; f.dateFormat = format
            if let d = f.date(from: text) { return d }
        }
        throw ValidationErrorText("Can't read the date “\(text)”. Use \"2026-10-20 18:30\", \"+2h\", \"+1d\" or \"now\".")
    }

    struct Schedule: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Plan a post (exported and uploaded by `publish run-due` when it's time).",
                                                        discussion: "Example: clipper publish schedule \"3 tips\" --to youtube,tiktok --at \"2026-10-20 18:30\"")
        @OptionGroup var lib: LibraryOptions
        @Argument(help: "Project name or id prefix.") var project: String
        @Option(help: "Timeline index within the project.") var timeline = 0
        @Option(help: "Comma-separated: youtube, tiktok, instagram.") var to: String
        @Option(help: "When: \"2026-10-20 18:30\", \"+2h\", \"now\".") var at = "now"
        @Option(help: "Title (default: the timeline's name).") var title: String?
        @Option(help: "Description text (music credits are always appended).") var description = ""
        @Option(help: "Comma-separated tags/hashtags.") var tags = ""
        @Option(help: "private, unlisted or public.") var visibility = "private"
        @Option(help: "Export preset.") var preset = "shorts-1080x1920"

        func run() async throws {
            let s = try Services(lib)
            let p = try s.findProject(project)
            guard p.timelines.indices.contains(timeline) else { throw ValidationErrorText("Project has \(p.timelines.count) timeline(s)") }
            let platforms = try to.split(separator: ",").map { raw -> Platform in
                guard let pl = Platform(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased()) else {
                    throw ValidationErrorText("Unknown platform “\(raw)”. Use youtube, tiktok, instagram.")
                }
                return pl
            }
            guard let vis = Visibility(rawValue: visibility) else { throw ValidationErrorText("Visibility must be private, unlisted or public") }
            let post = ScheduledPost(projectID: p.id, timelineIndex: timeline, platforms: platforms,
                                     title: title ?? p.timelines[timeline].name, description: description,
                                     tags: tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                                     visibility: vis, scheduledAt: try Publish.parseDate(at), presetID: preset)
            try Publish.queue(s).add(post)
            let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
            Console.line("Scheduled “\(post.title)” for \(df.string(from: post.scheduledAt)) → \(platforms.map(\.displayName).joined(separator: ", ")) (\(post.id.uuidString.prefix(8)))")
        }
    }

    struct ListPosts: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "Show the publishing queue.")
        @OptionGroup var lib: LibraryOptions
        func run() async throws {
            let posts = try Publish.queue(try Services(lib)).posts()
            let df = DateFormatter(); df.dateStyle = .short; df.timeStyle = .short
            Console.table([["ID", "WHEN", "STATUS", "PLATFORMS", "TITLE", "RESULT"]] + posts.map { p in
                [String(p.id.uuidString.prefix(8)), df.string(from: p.scheduledAt), p.status.rawValue,
                 p.platforms.map(\.rawValue).joined(separator: ","), p.title,
                 (p.results.map { "\($0.platform.rawValue): \($0.url?.absoluteString ?? $0.remoteID)" } + p.errors.map { "\($0.key): ⚠️ \($0.value)" })
                    .joined(separator: "; ")]
            })
        }
    }

    struct Calendar: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Write the schedule as an .ics calendar (subscribe from Apple/Google Calendar or Notion).")
        @OptionGroup var lib: LibraryOptions
        @Option(name: .shortAndLong, help: "Output .ics path (default: <library>/Publishing/clipper.ics).") var output: String?
        func run() async throws {
            let s = try Services(lib)
            let q = Publish.queue(s)
            let url = output.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? q.url.deletingLastPathComponent().appendingPathComponent("clipper.ics")
            try PublishCalendar.ics(try q.posts()).write(to: url, atomically: true, encoding: .utf8)
            Console.line("Wrote \(url.path). In Calendar: File ▸ New Calendar Subscription… → file://\(url.path)")
        }
    }

    struct Cancel: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Cancel a scheduled post.")
        @OptionGroup var lib: LibraryOptions
        @Argument(help: "Post id prefix.") var id: String
        func run() async throws {
            let q = Publish.queue(try Services(lib))
            guard let p = try q.posts().first(where: { $0.id.uuidString.lowercased().hasPrefix(id.lowercased()) }) else {
                throw ValidationErrorText("No post \(id)")
            }
            try q.update(p.id) { $0.status = .cancelled }
            Console.line("Cancelled “\(p.title)”")
        }
    }
}
