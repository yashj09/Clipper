import AppKit
import ClipperAnalysis
import ClipperAutomation
import ClipperCore
import ClipperEngine
import ClipperLibrary
import Foundation
import Observation

/// What the user asked the draft sheet for.
struct DraftRequest {
    var template: Template
    /// Ordered primary clips.
    var primary: [AssetID]
    /// Other slots → clips.
    var slots: [String: [AssetID]] = [:]
    var title: String = ""
    var captions = true
    var music = true
    var musicID: String?
    var maxDuration: Double?
    var seed: UInt64 = 1
}

/// A long-running task shown in the window (import, analysis, export).
struct Activity: Equatable {
    var title: String
    var detail: String = ""
    var progress: Double?
}

/// App-wide state: the library and everything in it, plus the open editor.
@MainActor @Observable
final class AppModel {
    enum Section: Hashable { case media, music, templates, publishing, project(UUID) }

    private(set) var library: Library?
    var libraryError: String?
    private(set) var assets: [MediaAsset] = []
    private(set) var projects: [ProjectSummary] = []
    private(set) var music: [MusicTrack] = []
    private(set) var templates: [Template] = BuiltIns.templates
    var settings = ClipperSettings()
    var section: Section = .media
    private(set) var editor: EditorModel?
    var activity: Activity?
    var alert: String?
    var draftSheet: [AssetID]?
    var exportSheet = false
    var highlightSession: HighlightSession?
    var saveTemplateSheet = false
    var publishSheet = false
    var templateEdit: TemplateEditRequest?

    @ObservationIgnored private let watcher = FolderWatcher()
    /// Watch-folder settings the watcher was last started with.
    @ObservationIgnored private var watching: ClipperSettings.Integrations?

    init() {
        do {
            let lib = try Library.openOrCreate(at: Library.defaultURL)
            library = lib
            settings = (try? lib.settings()) ?? ClipperSettings()
            refresh()
            restartWatching()
            recoverInterruptedPosts()
        } catch {
            libraryError = "Couldn't open the library at \(Library.defaultURL.path): \(error)"
        }
    }

    func refresh() {
        guard let library else { return }
        assets = ((try? library.assets()) ?? []).filter { !$0.tags.contains("music") }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        projects = (try? library.projects()) ?? []
        music = (try? library.music()) ?? []
        templates = BuiltIns.templates + ((try? library.userTemplates()) ?? [])
    }

    var allAssets: [AssetID: MediaAsset] {
        Dictionary(uniqueKeysWithValues: ((try? library?.assets()) ?? []).map { ($0.id, $0) })
    }

    // MARK: Import

    func importFiles(_ urls: [URL]) async {
        guard let library else { return }
        let dir = library.mediaURL.appendingPathComponent("Transcoded", isDirectory: true)
        for (i, url) in urls.enumerated() {
            activity = Activity(title: "Importing", detail: "\(i + 1)/\(urls.count) \(url.lastPathComponent)", progress: Double(i) / Double(urls.count))
            do {
                _ = try await library.importMedia([url], mode: .reference) { u in try await Transcoder.makeAsset(u, transcodeDirectory: dir) }
            } catch {
                alert = "Couldn't import \(url.lastPathComponent): \(error)"
            }
        }
        activity = nil
        refresh()
    }

    func chooseAndImport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .audio, .image]
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await importFiles(urls) }
    }

    // MARK: Projects

    func open(_ id: UUID) {
        guard let library else { return }
        // Write the current editor's last edits before it is replaced (and before reloading, if it's this project).
        editor?.flushSave()
        do {
            let project = try library.loadProject(id)
            let editor = EditorModel(project: project, assets: allAssets, settings: settings)
            editor.onChange = { [weak self] p in self?.save(p) }
            self.editor = editor
            section = .project(id)
        } catch { alert = "Couldn't open project: \(error)" }
    }

    func save(_ project: Project) {
        do { _ = try library?.saveProject(project); projects = (try? library?.projects()) ?? projects } catch { alert = "Save failed: \(error)" }
    }

    func delete(_ id: UUID) {
        if editor?.project.id == id {
            editor?.discardPendingSave()   // a late save would bring the deleted project back
            if case .project(id) = section { section = .media }
            editor = nil
        } else {
            editor?.flushSave()
        }
        try? library?.deleteProject(id)
        refresh()
    }

    /// Saves pending edits before the app quits.
    func prepareForTermination() { editor?.flushSave() }

    // MARK: Draft

    func createDraft(_ request: DraftRequest) async {
        guard let library else { return }
        let byID = allAssets
        let primary = request.primary.compactMap { byID[$0] }
        let others = request.slots.flatMap { slot, ids in ids.compactMap { byID[$0] }.map { ($0, slot) } }
        let all = primary.map { ($0, nil as String?) } + others.map { ($0.0, Optional($0.1)) }
        guard !primary.isEmpty else { alert = "Add at least one clip to the \(request.template.primarySlot?.name ?? "main") slot."; return }

        // Analysis (cached by content, so re-drafting the same clips is instant).
        var kinds: Set<AnalysisKind> = []
        let rules = request.template.rules
        if rules.silenceCut != nil || rules.captions != nil || rules.duck != nil { kinds.formUnion([.speech, .transcript]) }
        if settings.automation.faceTracking, request.template.slots.contains(where: { $0.reframe == .face }) { kinds.insert(.faces) }
        let pipeline = AnalysisPipeline(cache: library.analysisCache,
                                        options: AnalysisOptions(locale: Locale(identifier: settings.automation.transcriptionLocale)))
        var analysis: [AssetID: AssetAnalysis] = [:]
        do {
            for (i, (asset, _)) in all.enumerated() where analysis[asset.id] == nil {
                activity = Activity(title: "Analyzing", detail: "\(i + 1)/\(all.count) \(asset.name)", progress: Double(i) / Double(all.count))
                analysis[asset.id] = try await pipeline.analyze(asset, kinds: kinds.filter { k in
                    (k != .speech && k != .transcript) || asset.info.hasAudio
                }) { kind, fraction in
                    Task { @MainActor in self.activity?.detail = "\(i + 1)/\(all.count) \(asset.name) — \(kind.rawValue) \(Int(fraction * 100))%" }
                }
            }
        } catch {
            activity = nil
            alert = "Analysis failed: \(error)"
            return
        }

        activity = Activity(title: "Drafting", detail: request.template.name)
        let musicPool = music.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        let name = request.title.isEmpty ? (primary.first?.name ?? "Untitled") : request.title
        let input = DraftInput(template: request.template,
                               clips: all.map { ClipInput(asset: $0.0, analysis: analysis[$0.0.id] ?? AssetAnalysis(), slot: $0.1) },
                               music: request.music ? musicPool : [],
                               settings: DraftSettings(title: request.title.isEmpty ? nil : request.title, seed: request.seed,
                                                       captions: request.captions, music: request.music,
                                                       maxDuration: request.maxDuration, musicID: request.musicID, name: name))
        let result = DraftPipeline.run(input)
        do {
            for asset in result.addedAssets { _ = try await library.importMedia([asset.url], mode: .reference) { _ in asset } }
            let saved = try library.saveProject(Project(name: name, timelines: [result.timeline]))
            refresh()
            open(saved.id)
            activity = nil
            let summary = (result.report.notes + result.report.warnings.map { "⚠️ " + $0 }).joined(separator: "\n")
            if !result.report.warnings.isEmpty { alert = "Draft created.\n\n" + summary }
        } catch {
            activity = nil
            alert = "Couldn't save the draft: \(error)"
        }
    }

    // MARK: Highlights (long recordings → many shorts)

    func findHighlights(_ asset: MediaAsset, count: Int = 12) async {
        guard let library else { return }
        let pipeline = AnalysisPipeline(cache: library.analysisCache,
                                        options: AnalysisOptions(locale: Locale(identifier: settings.automation.transcriptionLocale)))
        activity = Activity(title: "Finding highlights", detail: asset.name, progress: 0)
        do {
            var kinds: Set<AnalysisKind> = [.events, .visual]
            if asset.info.hasAudio { kinds.formUnion([.speech, .transcript]) }
            let analysis = try await pipeline.analyze(asset, kinds: kinds) { kind, fraction in
                Task { @MainActor in self.activity?.detail = "\(asset.name) — \(kind.rawValue) \(Int(fraction * 100))%" }
            }
            let options = HighlightOptions(count: count)
            var picks = HighlightFinder.find(analysis, duration: asset.info.duration.seconds, options: options)
            var rankedBy = "Ranked by signals (no AI)"
            if settings.automation.useLLM, let url = URL(string: settings.automation.llmBaseURL) {
                let ranker = LocalLLMRanker(endpoint: LLMEndpoint(baseURL: url, model: settings.automation.llmModel))
                if await ranker.isAvailable() {
                    activity?.detail = "Ranking with \(settings.automation.llmModel)…"
                    let pool = HighlightFinder.select(HighlightFinder.candidates(analysis, duration: asset.info.duration.seconds, options: options), count: count * 3)
                    picks = Array(try await ranker.rank(pool, context: asset.name).prefix(count))
                    rankedBy = "Ranked with \(settings.automation.llmModel) (local)"
                } else {
                    rankedBy = "Local LLM not reachable — ranked by signals"
                }
            }
            activity = nil
            if picks.isEmpty { alert = "No highlights found in \(asset.name)."; return }
            highlightSession = HighlightSession(asset: asset, analysis: analysis, highlights: picks, rankedBy: rankedBy)
        } catch {
            activity = nil
            alert = "Highlight search failed: \(error)"
        }
    }

    func createShorts(from session: HighlightSession, highlights: [Highlight], template: Template) async {
        guard let library else { return }
        activity = Activity(title: "Drafting shorts", detail: "\(highlights.count) highlights")
        let pool = music.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        var timelines: [Timeline] = []
        do {
            for (i, h) in highlights.enumerated() {
                let name = "\(i + 1). " + (h.title ?? h.text.split(separator: " ").prefix(6).joined(separator: " "))
                let result = DraftPipeline.run(DraftInput(template: template,
                                                          clips: [ClipInput(asset: session.asset, analysis: session.analysis, inPoint: h.start, outPoint: h.end)],
                                                          music: settings.automation.music ? pool : [],
                                                          settings: DraftSettings(title: h.title, seed: UInt64(i + 1), name: name)))
                for a in result.addedAssets { _ = try await library.importMedia([a.url], mode: .reference) { _ in a } }
                timelines.append(result.timeline)
            }
            let saved = try library.saveProject(Project(name: "\(session.asset.name) highlights", timelines: timelines))
            refresh()
            open(saved.id)
        } catch { alert = "Couldn't create shorts: \(error)" }
        activity = nil
    }

    // MARK: Export

    func export(preset: ExportPreset, to url: URL) async {
        guard let editor else { return }
        let timeline = editor.timeline
        let assets = editor.assets
        activity = Activity(title: "Exporting", detail: preset.name, progress: 0)
        do {
            let result = try await Exporter.export(timeline, assets: assets, preset: preset.applying(settings.export), to: url) { p in
                Task { @MainActor in self.activity?.progress = p.fraction; self.activity?.detail = String(format: "%@ — %.0f fps", preset.name, p.framesPerSecond) }
            }
            activity = nil
            NSWorkspace.shared.activateFileViewerSelecting([result.url])
        } catch {
            activity = nil
            alert = "Export failed: \(error)"
        }
    }

    // MARK: Music

    func addStarterPack() async {
        guard let library else { return }
        activity = Activity(title: "Music", detail: "Fetching the free starter pack…")
        do {
            let (data, _) = try await URLSession.shared.data(from: IncompetechCatalog.catalogURL)
            let pieces = IncompetechCatalog.starterPack(try IncompetechCatalog.decode(data))
            let dir = library.url.appendingPathComponent("Music/Incompetech", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var tracks: [MusicTrack] = []
            for (i, p) in pieces.enumerated() {
                activity = Activity(title: "Music", detail: "\(i + 1)/\(pieces.count) \(p.title)", progress: Double(i) / Double(pieces.count))
                // The catalog is remote data: never let its file name pick a path outside the folder.
                guard let name = p.localFileName, let source = p.downloadURL else { continue }
                let file = dir.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: file.path) {
                    let (tmp, response) = try await URLSession.shared.download(from: source)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                    try FileManager.default.moveItem(at: tmp, to: file)
                }
                let a = try await MusicAnalyzer.analyze(url: file)
                var t = p.track(localURL: file)
                t.duration = a.duration; t.beats = a.beats; t.energy = a.energy
                if a.beats.bpm > 0 { t.bpm = a.beats.bpm }
                tracks.append(t)
            }
            try library.upsertMusic(tracks)
        } catch { alert = "Couldn't add the starter pack: \(error)" }
        activity = nil
        refresh()
    }

    // MARK: Templates

    /// Builds a template from the open timeline (based on the template it was drafted from) and stores it.
    func saveTemplateFromEditor(name: String) -> [String] {
        guard let editor, let library else { return ["No open timeline"] }
        let tl = editor.timeline
        let based = tl.provenance.flatMap { p in templates.first { $0.id == p.template } }
        var id = TemplateBuilder.slug(name)
        while templates.contains(where: { $0.id == id }) { id += "-2" }
        let r = TemplateBuilder.make(from: tl, id: id, name: name, basedOn: based)
        do { try library.saveTemplate(r.template) } catch { return ["Couldn't save: \(error)"] }
        refresh()
        return ["Template “\(r.template.name)” saved"] + r.notes
    }

    func saveTemplate(_ t: Template) {
        do { try library?.saveTemplate(t); refresh() } catch { alert = "Couldn't save template: \(error)" }
    }

    func deleteTemplate(_ id: String) {
        try? library?.deleteTemplate(id: id)
        refresh()
    }

    var userTemplateIDs: Set<String> { Set(((try? library?.userTemplates()) ?? []).map(\.id)) }

    // MARK: Generated music

    /// Generates instrumental tracks on this Mac (ACE-Step via the optional Python worker) and adds them to the library.
    /// The worker is shut down afterwards: a loaded model holds ~11 GB of memory.
    func generateMusic(prompt: String, duration: Double, bpm: Double?, variations: Int) async {
        guard let library else { return }
        guard let generator = MusicGenerator.makeDefault() else {
            alert = "Music generation needs uv (brew install uv) and Clipper's worker folder. See worker/README.md."
            return
        }
        activity = Activity(title: "Generating music", detail: "Starting the local model (first run downloads ~6.3 GB)…", progress: 0)
        var tracks: [MusicTrack] = []
        do {
            for v in 0..<max(1, variations) {
                let track = try await generator.generate(prompt: prompt, duration: duration, bpm: bpm, seed: v,
                                                         outputDirectory: library.url.appendingPathComponent("Music/Generated")) { p in
                    Task { @MainActor in
                        self.activity?.progress = (Double(v) + p.fraction) / Double(max(1, variations))
                        self.activity?.detail = "Take \(v + 1)/\(variations) — \(p.message ?? "")"
                    }
                }
                tracks.append(track)
            }
            try library.upsertMusic(tracks)
        } catch {
            alert = "Music generation failed: \(error)"
        }
        await generator.worker.shutdown()
        activity = nil
        refresh()
    }

    /// Called on every settings change (each keystroke in a text field): the file write is small, but the folder
    /// watcher is only restarted when the watch settings actually changed.
    func saveSettings() {
        try? library?.saveSettings(settings)
        if editor?.settings != settings { editor?.settings = settings }
        if watching != settings.integrations { restartWatching() }
    }

    // MARK: Watch folders

    func restartWatching() {
        watching = settings.integrations
        watcher.start(folders: settings.integrations.watchFolders) { [weak self] url in
            guard let self else { return }
            let before = Set(self.assets.map(\.id))
            await self.importFiles([url])
            guard let id = self.templates.first(where: { $0.id == self.settings.integrations.watchTemplate })?.id,
                  let template = self.templates.first(where: { $0.id == id }),
                  let asset = self.assets.first(where: { !before.contains($0.id) && $0.url.path == url.path }) else { return }
            await self.createDraft(DraftRequest(template: template, primary: [asset.id], captions: self.settings.automation.captions,
                                                music: self.settings.automation.music))
        }
    }
}
