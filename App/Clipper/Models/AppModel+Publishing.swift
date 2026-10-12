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

    func schedule(_ post: ScheduledPost) {
        do { try publishQueue?.add(post); writeCalendar() } catch { alert = "Couldn't schedule: \(error)" }
    }

    func writeCalendar() {
        guard let q = publishQueue, let posts = try? q.posts() else { return }
        try? PublishCalendar.ics(posts).write(to: q.url.deletingLastPathComponent().appendingPathComponent("clipper.ics"),
                                              atomically: true, encoding: .utf8)
    }

    func runDuePosts() async {
        guard let q = publishQueue, let due = try? q.due() else { return }
        for post in due { await execute(post) }
    }

    /// Exports the post's timeline (once) and uploads it to each remaining platform, recording results in the queue.
    func execute(_ post: ScheduledPost) async {
        guard let library, let q = publishQueue else { return }
        do {
            let project = try library.loadProject(post.projectID)
            let timeline = project.timelines[post.timelineIndex]
            var file = post.exportedFile
            if file == nil || !FileManager.default.fileExists(atPath: file!.path) {
                try q.update(post.id) { $0.status = .exporting }
                guard let preset = ExportPreset.named(post.presetID) else { throw CocoaError(.featureUnsupported) }
                let out = q.url.deletingLastPathComponent().appendingPathComponent("Exports/\(post.id.uuidString.prefix(8)).mp4")
                activity = Activity(title: "Exporting", detail: post.title, progress: 0)
                let result = try await Exporter.export(timeline, assets: allAssets, preset: preset, to: out) { p in
                    Task { @MainActor in self.activity?.progress = p.fraction }
                }
                file = result.url
                try q.update(post.id) { $0.exportedFile = file }
            }
            try q.update(post.id) { $0.status = .uploading }
            let captions = ((try? FileManager.default.contentsOfDirectory(at: file!.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "srt" && $0.lastPathComponent.hasPrefix(file!.deletingPathExtension().lastPathComponent) }
            for platform in post.remainingPlatforms {
                activity = Activity(title: "Uploading to \(platform.displayName)", detail: post.title, progress: 0)
                let request = PublishRequest(file: file!, title: post.title, description: post.description, tags: post.tags,
                                             visibility: platform == .instagram ? .public : post.visibility,
                                             captions: captions, attributions: timeline.attributions)
                do {
                    let publisher = try PublisherFactory.publisher(for: platform, store: credentialStore)
                    let result = try await publisher.publish(request) { p in
                        Task { @MainActor in self.activity?.progress = p.fraction; self.activity?.detail = p.message }
                    }
                    try q.update(post.id) { $0.results.append(result); $0.errors[platform.rawValue] = nil }
                } catch {
                    try q.update(post.id) { $0.errors[platform.rawValue] = "\(error)" }
                }
            }
            try q.update(post.id) { p in p.status = p.remainingPlatforms.isEmpty ? .posted : (p.results.isEmpty ? .failed : .partial) }
        } catch {
            try? q.update(post.id) { $0.status = .failed; $0.errors["export"] = "\(error)" }
            alert = "Publishing “\(post.title)” failed: \(error)"
        }
        activity = nil
        writeCalendar()
        if let done = try? q.posts().first(where: { $0.id == post.id }) {
            let lines = done.results.map { "✓ \($0.platform.displayName): \($0.url?.absoluteString ?? $0.remoteID)\n   \($0.status)" }
                + done.errors.map { "⚠️ \($0.key): \($0.value)" }
            alert = "“\(done.title)”\n\n" + lines.joined(separator: "\n")
        }
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
