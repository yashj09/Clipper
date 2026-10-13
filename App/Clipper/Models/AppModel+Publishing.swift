import AppKit
import ClipperCore
import ClipperEngine
import ClipperLibrary
import ClipperPublish
import Foundation

/// Publishing: accounts (Keychain), queue, export + upload. Nothing is posted unless the user asks.
extension AppModel {
    var credentialStore: any CredentialStore { KeychainCredentialStore() }

    var publishQueue: PublishQueue? {
        library.map { PublishQueue(directory: $0.url.appendingPathComponent("Publishing", isDirectory: true)) }
    }

    func isConnected(_ platform: Platform) async -> Bool {
        guard let p = try? PublisherFactory.publisher(for: platform, store: credentialStore) else { return false }
        return await p.isConnected()
    }

    /// YouTube/TikTok: opens the browser and waits for the loopback callback.
    func connect(_ platform: Platform) async {
        do {
            activity = Activity(title: "Connecting \(platform.displayName)", detail: "Finish signing in in your browser…")
            _ = try await PublisherFactory.connect(platform: platform, store: credentialStore) { url in
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            }
            activity = nil
        } catch {
            activity = nil
            alert = "Couldn't connect \(platform.displayName): \(error)"
        }
    }

    /// Instagram's two-step login: open the consent page, then the user pastes the redirected URL.
    func instagramAuthorizeURL() -> (URL, String)? {
        let state = InstagramAuth.makeState()
        guard let url = try? InstagramAuth(credentials: credentialStore).authorizeURL(state: state) else {
            alert = "Enter the Instagram app ID, secret and redirect URI first."
            return nil
        }
        return (url, state)
    }

    func finishInstagram(pasted: String, state: String) async {
        do { _ = try await InstagramAuth(credentials: credentialStore).connect(pastedRedirect: pasted, expectedState: state) }
        catch { alert = "Instagram sign-in failed: \(error)" }
    }

    func disconnect(_ platform: Platform) {
        try? PublisherFactory.disconnect(platform: platform, store: credentialStore)
    }

    // MARK: Queue

    /// Adds the post to the queue; false (with an alert) if it couldn't be stored.
    @discardableResult
    func schedule(_ post: ScheduledPost) -> Bool {
        guard let q = publishQueue else { return false }
        do { try q.add(post); writeCalendar(); return true } catch { alert = "Couldn't schedule: \(error)"; return false }
    }

    func writeCalendar() {
        guard let q = publishQueue, let posts = try? q.posts() else { return }
        try? PublishCalendar.ics(posts).write(to: q.url.deletingLastPathComponent().appendingPathComponent("clipper.ics"),
                                              atomically: true, encoding: .utf8)
    }

    /// The shared runner (claims posts, so the LaunchAgent's `run-due` and the app never publish one twice). Exports
    /// always write caption sidecars: YouTube uploads them as captions.
    func publishRunner(_ q: PublishQueue, library: Library) -> PublishRunner {
        let store = credentialStore
        return PublishRunner(queue: q, loadTimeline: { post in
            let project = try library.loadProject(post.projectID)
            guard project.timelines.indices.contains(post.timelineIndex) else {
                throw CocoaError(.fileReadNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Timeline \(post.timelineIndex + 1) no longer exists in “\(project.name)”."])
            }
            return project.timelines[post.timelineIndex]
        }, export: { timeline, preset, url in
            let assets = Dictionary(uniqueKeysWithValues: try library.assets().map { ($0.id, $0) })
            return try await Exporter.export(timeline, assets: assets, preset: preset, to: url) { p in
                Task { @MainActor in self.activity?.progress = p.fraction }
            }.url
        }, publisher: { platform in
            try PublisherFactory.publisher(for: platform, store: store)
        }, events: { event in
            await MainActor.run {
                switch event {
                case .exporting(let post): self.activity = Activity(title: "Exporting", detail: post.title, progress: 0)
                case .uploading(let post, let platform):
                    self.activity = Activity(title: "Uploading to \(platform.displayName)", detail: post.title, progress: 0)
                case .published, .failed: break
                }
            }
        }, progress: { _, p in
            Task { @MainActor in self.activity?.progress = p.fraction; self.activity?.detail = p.message }
        })
    }

    func runDuePosts() async {
        guard let library, let q = publishQueue else { return }
        do {
            let done = try await publishRunner(q, library: library).runDue()
            activity = nil
            writeCalendar()
            if done.isEmpty { alert = "Nothing due (or already being published by the LaunchAgent)." }
            else { alert = done.map(summary).joined(separator: "\n\n") }
        } catch {
            activity = nil
            alert = "Publishing failed: \(error)"
        }
    }

    /// Exports the post's timeline (once) and uploads it to each remaining platform, recording results in the queue.
    /// Does nothing if the post is already being published (e.g. by the LaunchAgent) or is finished.
    func execute(_ post: ScheduledPost) async {
        guard let library, let q = publishQueue else { return }
        do {
            let done = try await publishRunner(q, library: library).run(post.id)
            activity = nil
            writeCalendar()
            alert = done.map(summary) ?? "“\(post.title)” is already being published or is no longer pending."
        } catch {
            activity = nil
            alert = "Publishing “\(post.title)” failed: \(error)"
        }
    }

    private func summary(_ done: ScheduledPost) -> String {
        let lines = done.results.map { "✓ \($0.platform.displayName): \($0.url?.absoluteString ?? $0.remoteID)\n   \($0.status)" }
            + done.errors.sorted { $0.key < $1.key }.map { "⚠️ \($0.key): \($0.value)" }
        return "“\(done.title)”\n\n" + lines.joined(separator: "\n")
    }

    /// Puts posts whose run was cut short (the app or CLI quit mid-publish) back in the queue.
    func recoverInterruptedPosts() {
        guard let q = publishQueue, let recovered = try? q.recoverInterrupted(), !recovered.isEmpty else { return }
        writeCalendar()
    }

    // MARK: Interchange

    func exportInterchange(fcpxml: Bool) {
        guard let editor else { return }
        let tl = editor.timeline
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fcpxml ? FCPXMLExporter.suggestedFileName(projectName: tl.name) : OTIOExporter.suggestedFileName(projectName: tl.name)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = fcpxml ? try FCPXMLExporter(projectName: tl.name).export(tl, assets: editor.assets)
                              : try OTIOExporter().export(tl, assets: editor.assets)
            try data.write(to: url)
            if fcpxml, !Subtitles.cues(tl).isEmpty {
                try FCPXMLExporter.captionsSRT(tl).write(to: url.deletingPathExtension().appendingPathExtension("srt"), atomically: true, encoding: .utf8)
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { alert = "Export failed: \(error)" }
    }
}
