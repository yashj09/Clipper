import ArgumentParser
import ClipperAnalysis
import ClipperAutomation
import ClipperCore
import ClipperEngine
import ClipperLibrary
import Foundation

struct Draft: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Import clips, analyze them, build a draft from a template, save it as a project and optionally export.",
        discussion: """
        Examples:
          clipper draft --template talking-head --title "3 tips" take1.mov take2.mov --export
          clipper draft --template gameplay match.mov --slot facecam=cam.mov --export
          clipper draft -t talking-head take.mov --slot broll=desk.mov --slot broll=camera.mov   # cut away where named
          clipper draft --template montage trip/*.mov --title "Lisbon"
          clipper draft -t talking-head take.mov --llm ollama --model qwen3:14b --brief   # title from a local LLM
        """)

    @OptionGroup var lib: LibraryOptions
    @Option(name: .shortAndLong, help: "Template id (talking-head, gameplay, montage, vlog, or a user template) or a .json file.")
    var template: String
    @Argument(help: "Clips for the template's primary slot, in order.")
    var files: [String]
    @Option(name: .customLong("slot"), help: "Assign a clip to another slot: <slot>=<file> (repeatable).")
    var slots: [String] = []
    @Option(name: .customLong("broll-tag"), help: "Offer every library video with this tag as B-roll (repeatable).")
    var brollTags: [String] = []
    @Option(help: "Title text for the template's title element.") var title: String?
    @Option(help: "Project name (default: title or first clip name).") var name: String?
    @Option(help: "Maximum duration in seconds (overrides the template).") var max: Double?
    @Option(help: "Random seed for choices like music (same seed → same draft).") var seed: UInt64 = 1
    @Option(help: "Force a music track by id (see `clipper music list`).") var music: String?
    @Flag(help: "Disable music.") var noMusic = false
    @Flag(help: "Disable captions.") var noCaptions = false
    @Flag(help: "Copy media into the library instead of referencing it in place.") var copy = false
    @Flag(help: "Export after drafting.") var export = false
    @Option(help: "Export preset id (default: template's preset).") var preset: String?
    @Option(name: .shortAndLong, help: "Output file for --export.") var output: String?
    @Flag(help: "Print the timeline JSON.") var json = false
    @OptionGroup(title: "Local LLM brief (title, hook, chapters, hashtags)") var llm: LLMOptions
    @Flag(help: "Print each clip's brief (needs --llm).") var brief = false

    func validate() throws {
        if brief, llm.llm == nil { throw ValidationError("--brief needs --llm") }
    }

    func run() async throws {
        let s = try Services(lib)
        let template = try s.template(self.template)
        Console.line("Template: \(template.name) — \(template.summary)")

        let primary = try await s.importFiles(files, copy: copy)
        var clips = primary.map { ($0, nil as String?) }
        for spec in slots {
            let parts = spec.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, template.slots.contains(where: { $0.id == parts[0] }) else {
                throw ValidationErrorText("--slot expects <slot>=<file> with a slot of \(template.id): \(template.slots.map(\.id).joined(separator: ", "))")
            }
            clips += try await s.importFiles([parts[1]], copy: copy).map { ($0, parts[0]) }
        }
        if !brollTags.isEmpty {
            guard let slot = template.slots.first(where: { $0.role == .broll }) else {
                throw ValidationErrorText("--broll-tag needs a template with a B-roll slot; \(template.id) has none")
            }
            let wanted = Set(brollTags.map { $0.lowercased() }), given = Set(clips.map(\.0.id))
            let tagged = try s.library.assets().filter { a in
                a.info.hasVideo && !given.contains(a.id) && a.tags.contains { wanted.contains($0.lowercased()) }
            }
            if tagged.isEmpty { Console.line("No library video is tagged \(brollTags.joined(separator: " or "))") }
            clips += tagged.map { ($0, slot.id) }
        }

        let endpoint = try llm.endpoint()
        var analysis: [AssetID: AssetAnalysis] = [:]
        var slotOrder: [String?] = []
        for (_, slot) in clips where !slotOrder.contains(slot) { slotOrder.append(slot) }
        for slot in slotOrder {
            var kinds = DraftPipeline.analysisKinds(for: template, slot: slot)
            if endpoint != nil { kinds.insert(.transcript) }
            guard !kinds.isEmpty else { continue }
            let found = try await s.analyze(clips.filter { $0.1 == slot }.map(\.0), kinds: kinds)
            analysis.merge(found) { first, _ in first }
        }
        if let endpoint { await s.addBriefs(to: &analysis, assets: clips.map(\.0), endpoint: endpoint, print: brief) }
        let draftTitle = title ?? primary.first.flatMap { analysis[$0.id]?.brief?.title }
        if title == nil, let draftTitle { Console.line("Title from \(endpoint?.model ?? "LLM"): “\(draftTitle)”") }
        let pool = try s.musicPool()
        let projectName = name ?? draftTitle ?? primary.first?.name ?? "Untitled"
        let input = DraftInput(template: template,
                               clips: clips.map { ClipInput(asset: $0.0, analysis: analysis[$0.0.id] ?? AssetAnalysis(), slot: $0.1) },
                               music: pool,
                               settings: DraftSettings(title: draftTitle, seed: seed, captions: noCaptions ? false : nil, music: noMusic ? false : nil,
                                                       maxDuration: max, musicID: music, name: projectName))
        let result = DraftPipeline.run(input)

        // The chosen music becomes a referenced library asset so the project can be reopened and re-exported.
        for asset in result.addedAssets {
            _ = try await s.library.importMedia([asset.url], mode: .reference) { _ in asset }
        }
        let tl = result.timeline
        Console.line(String(format: "Draft: %.1fs, %d items on %d tracks", tl.duration.seconds, tl.allItems.count, tl.tracks.count))
        result.report.notes.forEach { Console.line("  • \($0)") }
        result.report.warnings.forEach { Console.line("  ⚠️ \($0)") }

        let project = try s.library.saveProject(Project(name: projectName, timelines: [tl]))
        Console.line("Saved project \(project.name) (\(project.id.uuidString.prefix(8)))")
        if json { print(String(decoding: try ClipperJSON.encode(tl), as: UTF8.self)) }
        if export {
            try await s.export(tl, project: project.name, preset: preset ?? template.exportPreset, to: output)
        }
    }
}

struct Import: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Import media into the library.")
    @OptionGroup var lib: LibraryOptions
    @Argument var files: [String]
    @Flag(help: "Copy into the library instead of referencing in place.") var copy = false
    @Flag(help: "Also run speech/transcript/face analysis.") var analyze = false

    func run() async throws {
        let s = try Services(lib)
        let assets = try await s.importFiles(files, copy: copy)
        Console.table([["NAME", "KIND", "SIZE", "DURATION", "FPS", "HDR", "ID"]] + assets.map {
            [$0.name, $0.info.kind.rawValue, "\($0.info.displayWidth)×\($0.info.displayHeight)", String(format: "%.1fs", $0.info.duration.seconds),
             String(format: "%.2f%@", $0.info.frameRate, $0.info.isVFR ? " VFR" : ""), $0.info.transfer.rawValue, String($0.id.uuidString.prefix(8))]
        })
        if analyze { _ = try await s.analyze(assets.filter { $0.info.hasAudio || $0.info.hasVideo }, kinds: [.speech, .transcript, .faces, .loudness]) }
    }
}

struct Analyze: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Analyze library media (results are cached by content).")
    @OptionGroup var lib: LibraryOptions
    @Argument(help: "Asset names or id prefixes (default: all).") var assets: [String] = []
    @Option(help: "Comma-separated: speech,transcript,loudness,faces,beats,events,visual,color,keywords") var kinds = "speech,transcript,faces,keywords"
    @Flag(help: "Print transcripts.") var transcript = false

    func run() async throws {
        let s = try Services(lib)
        let selected = try s.assets(matching: assets).filter { !$0.tags.contains("music") }
        let k = Set(kinds.split(separator: ",").compactMap { AnalysisKind(rawValue: String($0)) })
        let results = try await s.analyze(selected, kinds: k)
        if transcript {
            for a in selected { if let t = results[a.id]?.transcript { Console.line("\n\(a.name):\n\(t.text)") } }
        }
    }
}

struct Export: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Export a project's timeline.")
    @OptionGroup var lib: LibraryOptions
    @Argument(help: "Project name or id prefix.") var project: String
    @Option(help: "Timeline index within the project.") var timeline = 0
    @Option(help: "Preset id (see `clipper presets`).") var preset: String?
    @Option(name: .shortAndLong) var output: String?

    func run() async throws {
        let s = try Services(lib)
        let p = try s.findProject(project)
        guard p.timelines.indices.contains(timeline) else { throw ValidationErrorText("Project has \(p.timelines.count) timeline(s)") }
        try await s.export(p.timelines[timeline], project: p.name, preset: preset, to: output)
    }
}

struct Projects: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List projects.")
    @OptionGroup var lib: LibraryOptions
    func run() async throws {
        let s = try Services(lib)
        let df = DateFormatter(); df.dateStyle = .short; df.timeStyle = .short
        Console.table([["ID", "NAME", "TIMELINES", "MODIFIED"]] + (try s.library.projects()).map {
            [String($0.id.uuidString.prefix(8)), $0.name, "\($0.timelineCount)", df.string(from: $0.modified)]
        })
    }
}

struct Templates: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List, export, save and validate templates.",
                                                    subcommands: [List.self, ExportJSON.self, Save.self, Validate.self],
                                                    defaultSubcommand: List.self)

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List built-in and your templates.")
        @OptionGroup var lib: LibraryOptions
        func run() async throws {
            let s = try Services(lib)
            let user = Set(try s.library.userTemplates().map(\.id))
            Console.table([["ID", "NAME", "CANVAS", "SLOTS", "SUMMARY"]] + (try s.templates()).map {
                [$0.id + (user.contains($0.id) ? " *" : ""), $0.name, "\($0.canvas.width)×\($0.canvas.height)@\($0.canvas.frameRate)",
                 $0.slots.map(\.id).joined(separator: ","), $0.summary]
            })
            if !user.isEmpty { Console.line("* your templates (stored in the library)") }
        }
    }

    struct ExportJSON: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "export", abstract: "Write templates as editable JSON files.")
        @OptionGroup var lib: LibraryOptions
        @Argument(help: "Destination folder.") var folder: String
        func run() async throws {
            let s = try Services(lib)
            let url = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let all = try s.templates()
            for t in all { try ClipperJSON.encode(t).write(to: url.appendingPathComponent("\(t.id).json")) }
            Console.line("Wrote \(all.count) templates to \(url.path). Edit one, then `clipper templates validate` and use it with --template file.json.")
        }
    }

    struct Save: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Save an edited project timeline as a reusable template.",
                                                        discussion: "Example: clipper templates save \"3 tips\" --name \"My talking head\"")
        @OptionGroup var lib: LibraryOptions
        @Argument(help: "Project name or id prefix.") var project: String
        @Option(help: "Timeline index within the project.") var timeline = 0
        @Option(help: "Template name.") var name: String
        @Option(help: "Template id (default: from the name).") var id: String?
        @Option(name: .customLong("file"), help: "Also write the JSON to this path.") var file: String?

        func run() async throws {
            let s = try Services(lib)
            let p = try s.findProject(project)
            guard p.timelines.indices.contains(timeline) else { throw ValidationErrorText("Project has \(p.timelines.count) timeline(s)") }
            let tl = p.timelines[timeline]
            let based = try tl.provenance.flatMap { prov in try s.templates().first { $0.id == prov.template } }
            let r = TemplateBuilder.make(from: tl, id: id ?? TemplateBuilder.slug(name), name: name, basedOn: based)
            try s.library.saveTemplate(r.template)
            Console.line("Saved template “\(r.template.name)” (\(r.template.id))" + (based.map { ", based on \($0.name)" } ?? ""))
            Console.line("  slots: " + r.template.slots.map { "\($0.id) [\($0.role.rawValue), \($0.fill.rawValue)]" }.joined(separator: ", "))
            r.notes.forEach { Console.line("  • \($0)") }
            if let file { try ClipperJSON.encode(r.template).write(to: URL(fileURLWithPath: (file as NSString).expandingTildeInPath)) }
        }
    }

    struct Validate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Check a template JSON file for mistakes.")
        @Argument var file: String
        @Flag(help: "Install it into the library if valid.") var install = false
        @OptionGroup var lib: LibraryOptions
        func run() async throws {
            let data = try Data(contentsOf: URL(fileURLWithPath: (file as NSString).expandingTildeInPath))
            let (template, issues) = TemplateValidator.decode(data)
            if issues.isEmpty, let template {
                Console.line("✓ \(template.name) (\(template.id)) is valid")
                if install { try Services(lib).library.saveTemplate(template); Console.line("Installed into the library.") }
            } else {
                issues.forEach { Console.line("✗ \($0)") }
                throw ExitCode(1)
            }
        }
    }
}

struct Presets: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List export presets.")
    func run() async throws {
        Console.table([["ID", "NAME", "CODEC", "LOUDNESS"]] + ExportPreset.builtIn.map {
            [$0.id, $0.name, $0.codec.rawValue, $0.loudness.map { "\(Int($0)) LUFS" } ?? "as mixed"]
        })
    }
}

struct Info: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show library location and contents.")
    @OptionGroup var lib: LibraryOptions
    func run() async throws {
        let s = try Services(lib)
        let assets = try s.library.assets()
        Console.line("Library: \(s.library.url.path)")
        Console.line("Media: \(assets.filter { !$0.tags.contains("music") }.count)  Music: \(try s.library.music().count)  Projects: \(try s.library.projects().count)")
        Console.line("Exports go to: \(try s.library.exportFolder().path)")
        Console.line("FFmpeg (import fallback): \(Transcoder.ffmpegURL?.path ?? "not found")")
    }
}
