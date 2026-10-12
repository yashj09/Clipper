import ArgumentParser
import ClipperCore
import ClipperLibrary
import ClipperPublish
import Darwin
import Foundation

struct Publish: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Schedule and publish to YouTube, TikTok and Instagram (your own developer apps; nothing is posted until you ask).",
        subcommands: [Connect.self, Status.self, Disconnect.self, Now.self, Schedule.self, ListPosts.self, RunDue.self, Calendar.self, Cancel.self, InstallAgent.self])

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

    // MARK: - Accounts

    static func store() -> any CredentialStore { KeychainCredentialStore() }

    static func platform(_ raw: String) throws -> Platform {
        guard let p = Platform(rawValue: raw.lowercased()) else { throw ValidationErrorText("Unknown platform “\(raw)”. Use youtube, tiktok, instagram.") }
        return p
    }

    /// Prompts on the terminal; secrets are read without echo.
    static func ask(_ label: String, secret: Bool) -> String? {
        if secret {
            var buf = [CChar](repeating: 0, count: 1024)
            guard let r = readpassphrase("\(label): ", &buf, buf.count, 0) else { return nil }
            return String(cString: r).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        print("\(label): ", terminator: "")
        return readLine()?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func openInBrowser(_ url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [url.absoluteString]
        try? p.run()
    }

    struct Connect: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Connect your account (stores your developer-app keys and sign-in in the macOS Keychain).",
            discussion: "Run `clipper publish connect youtube --help-setup` first to see how to create the developer app.")
        @Argument(help: "youtube, tiktok or instagram") var platform: String
        @Flag(help: "Print how to create the developer app and exit.") var helpSetup = false
        @Option(help: "Instagram: store a long-lived token generated in the Meta App Dashboard instead of signing in.") var token: String?

        func run() async throws {
            let p = try Publish.platform(platform)
            if helpSetup { Console.line(PublisherFactory.setupInstructions(for: p)); return }
            let store = Publish.store()
            let creds = PlatformCredentials(store: store)
            let missing = try creds.missingKeys(for: p)
            if !missing.isEmpty { Console.line("Enter your \(p.displayName) app credentials (see `clipper publish connect \(p.rawValue) --help-setup`):") }
            for field in missing {
                guard let value = Publish.ask(field.label, secret: field.isSecret), !value.isEmpty else { throw ValidationErrorText("\(field.label) is required") }
                try store.setString(value, for: field.key)
            }
            switch p {
            case .youtube, .tiktok:
                Console.line("Opening your browser to sign in to \(p.displayName)…")
                _ = try await PublisherFactory.connect(platform: p, store: store) { Publish.openInBrowser($0) }
                Console.line("✓ Connected \(p.displayName).")
            case .instagram:
                if try store.get(S3Config.credentialKey) == nil {
                    Console.line("Storage for the temporary public video URL (Cloudflare R2 or any S3-compatible bucket):")
                    guard let endpoint = Publish.ask("Endpoint (e.g. https://<account>.r2.cloudflarestorage.com)", secret: false).flatMap(URL.init(string:)),
                          let bucket = Publish.ask("Bucket", secret: false), !bucket.isEmpty,
                          let key = Publish.ask("Access key ID", secret: false), !key.isEmpty,
                          let secret = Publish.ask("Secret access key", secret: true), !secret.isEmpty else {
                        throw ValidationErrorText("Storage settings are required for Instagram")
                    }
                    let region = Publish.ask("Region [auto]", secret: false).flatMap { $0.isEmpty ? nil : $0 } ?? "auto"
                    try store.encode(S3Config(endpoint: endpoint, region: region, bucket: bucket, accessKeyID: key, secretAccessKey: secret),
                                     for: S3Config.credentialKey)
                }
                let auth = InstagramAuth(credentials: store)
                if let token {
                    _ = try await auth.storeDashboardToken(token)
                } else {
                    let state = InstagramAuth.makeState()
                    let url = try auth.authorizeURL(state: state)
                    Console.line("Opening Instagram sign-in. After approving, copy the URL from the address bar (the page may show an error).")
                    Publish.openInBrowser(url)
                    guard let pasted = Publish.ask("Paste the full redirected URL", secret: false), !pasted.isEmpty else {
                        throw ValidationErrorText("No URL pasted")
                    }
                    _ = try await auth.connect(pastedRedirect: pasted, expectedState: state)
                }
                Console.line("✓ Connected Instagram.")
            }
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show which platforms are connected.")
        func run() async throws {
            let store = Publish.store()
            var rows = [["PLATFORM", "APP KEYS", "ACCOUNT"]]
            for p in Platform.allCases {
                let missing = (try? PlatformCredentials(store: store).missingKeys(for: p)) ?? []
                var connected = false
                if let publisher = try? PublisherFactory.publisher(for: p, store: store) { connected = await publisher.isConnected() }
                rows.append([p.displayName, missing.isEmpty ? "✓" : "missing \(missing.map(\.label).joined(separator: ", "))",
                             connected ? "✓ connected" : "not connected"])
            }
            Console.table(rows)
        }
    }

    struct Disconnect: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Forget the account sign-in (and optionally the app keys).")
        @Argument var platform: String
        @Flag(help: "Also delete the developer-app keys.") var forgetKeys = false
        func run() async throws {
            let p = try Publish.platform(platform)
            try PublisherFactory.disconnect(platform: p, store: Publish.store(), forgetAppCredentials: forgetKeys)
            if p == .instagram, forgetKeys { try Publish.store().set(nil, for: S3Config.credentialKey) }
            Console.line("Disconnected \(p.displayName). (Revoke Clipper's access in your account's security settings too if you wish.)")
        }
    }

    // MARK: - Publishing

    /// Exports (if needed) and uploads one post to each remaining platform, updating the queue as it goes.
    static func execute(_ post: ScheduledPost, services s: Services, queue: PublishQueue) async throws {
        let project = try s.library.loadProject(post.projectID)
        guard project.timelines.indices.contains(post.timelineIndex) else { throw ValidationErrorText("Timeline \(post.timelineIndex) not found") }
        let timeline = project.timelines[post.timelineIndex]
        var file = post.exportedFile
        if file == nil || !FileManager.default.fileExists(atPath: file!.path) {
            try queue.update(post.id) { $0.status = .exporting }
            let dir = queue.url.deletingLastPathComponent().appendingPathComponent("Exports", isDirectory: true)
            let out = dir.appendingPathComponent(post.id.uuidString.prefix(8) + " " + timeline.name.replacingOccurrences(of: "/", with: "-"))
                .appendingPathExtension("mp4")
            file = try await s.export(timeline, project: project.name, preset: post.presetID, to: out.path)
            try queue.update(post.id) { $0.exportedFile = file }
        }
        let captions = ((try? FileManager.default.contentsOfDirectory(at: file!.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "srt" && $0.lastPathComponent.hasPrefix(file!.deletingPathExtension().lastPathComponent) }
        try queue.update(post.id) { $0.status = .uploading }
        let store = Publish.store()
        for platform in post.remainingPlatforms {
            let visibility: Visibility = platform == .instagram ? .public : post.visibility   // Reels have no private mode
            let request = PublishRequest(file: file!, title: post.title, description: post.description, tags: post.tags,
                                         visibility: visibility, captions: captions, attributions: timeline.attributions)
            do {
                let publisher = try PublisherFactory.publisher(for: platform, store: store)
                let result = try await publisher.publish(request) { p in Console.progress(p.fraction, "\(platform.displayName): \(p.message)") }
                Console.clearStatus()
                Console.line("  ✓ \(platform.displayName): \(result.url?.absoluteString ?? result.remoteID) — \(result.status)")
                try queue.update(post.id) { $0.results.append(result); $0.errors[platform.rawValue] = nil }
            } catch {
                Console.clearStatus()
                Console.line("  ⚠️ \(platform.displayName): \(error)")
                try queue.update(post.id) { $0.errors[platform.rawValue] = "\(error)" }
            }
        }
        try queue.update(post.id) { p in
            p.status = p.remainingPlatforms.isEmpty ? .posted : (p.results.isEmpty ? .failed : .partial)
        }
    }

    struct Now: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Export and publish a timeline right away.",
                                                        discussion: "Example: clipper publish now \"3 tips\" --to youtube --visibility unlisted")
        @OptionGroup var lib: LibraryOptions
        @Argument var project: String
        @Option var timeline = 0
        @Option(help: "Comma-separated platforms.") var to: String
        @Option var title: String?
        @Option var description = ""
        @Option var tags = ""
        @Option(help: "private, unlisted or public (Instagram Reels are always public).") var visibility = "private"
        @Option var preset = "shorts-1080x1920"

        func run() async throws {
            var schedule = try Schedule.parse([project, "--timeline", String(timeline), "--to", to, "--at", "now", "--description", description,
                                               "--tags", tags, "--visibility", visibility, "--preset", preset] + (title.map { ["--title", $0] } ?? []))
            schedule.lib = lib
            try await schedule.run()
            let s = try Services(lib)
            let q = Publish.queue(s)
            guard let post = try q.posts().filter({ $0.status == .scheduled }).max(by: { $0.updated < $1.updated }) else { return }
            try await Publish.execute(post, services: s, queue: q)
        }
    }

    struct RunDue: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "run-due", abstract: "Publish every post whose time has come (run by hand or by the LaunchAgent).")
        @OptionGroup var lib: LibraryOptions
        func run() async throws {
            let s = try Services(lib)
            let q = Publish.queue(s)
            let due = try q.due()
            if due.isEmpty { Console.line("Nothing due."); return }
            for post in due {
                Console.line("Publishing “\(post.title)” → \(post.remainingPlatforms.map(\.displayName).joined(separator: ", "))")
                do { try await Publish.execute(post, services: s, queue: q) } catch {
                    Console.line("  ⚠️ \(error)")
                    try q.update(post.id) { $0.status = .failed; $0.errors["export"] = "\(error)" }
                }
            }
            try PublishCalendar.ics(try q.posts()).write(to: q.url.deletingLastPathComponent().appendingPathComponent("clipper.ics"), atomically: true, encoding: .utf8)
        }
    }

    struct InstallAgent: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "install-agent",
            abstract: "Install a LaunchAgent that runs `publish run-due` every 15 minutes while you're logged in.")
        @OptionGroup var lib: LibraryOptions
        @Flag(help: "Remove the LaunchAgent instead.") var uninstall = false
        func run() async throws {
            let label = "dev.yashjain.clipper.publish"
            let plist = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
            let launchctl = { (args: [String]) in
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = args
                try? p.run(); p.waitUntilExit()
            }
            if uninstall {
                launchctl(["bootout", "gui/\(getuid())", plist.path])
                try? FileManager.default.removeItem(at: plist)
                Console.line("Removed \(plist.path)")
                return
            }
            let exe = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
            let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Clipper", isDirectory: true)
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            let dict: [String: Any] = [
                "Label": label,
                "ProgramArguments": [exe, "publish", "run-due", "--library", lib.url.path],
                "StartInterval": 900, "RunAtLoad": true,
                "StandardOutPath": logs.appendingPathComponent("publish.log").path,
                "StandardErrorPath": logs.appendingPathComponent("publish.log").path,
            ]
            try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0).write(to: plist)
            launchctl(["bootout", "gui/\(getuid())", plist.path])
            launchctl(["bootstrap", "gui/\(getuid())", plist.path])
            Console.line("Installed \(plist.path) (every 15 min; log: \(logs.path)/publish.log). Remove with --uninstall.")
        }
    }
}
