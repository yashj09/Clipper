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
          clipper draft --template montage trip/*.mov --title "Lisbon"
        """)

    @OptionGroup var lib: LibraryOptions
    @Option(name: .shortAndLong, help: "Template id (talking-head, gameplay, montage, vlog, or a user template) or a .json file.")
    var template: String
    @Argument(help: "Clips for the template's primary slot, in order.")
    var files: [String]
    @Option(name: .customLong("slot"), help: "Assign a clip to another slot: <slot>=<file> (repeatable).")
    var slots: [String] = []
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

        let kinds = Services.kinds(for: template)
        let analysis = kinds.isEmpty ? [:] : try await s.analyze(clips.map(\.0), kinds: kinds)
        let pool = try s.musicPool()
        let projectName = name ?? title ?? primary.first?.name ?? "Untitled"
        let input = DraftInput(template: template,
                               clips: clips.map { ClipInput(asset: $0.0, analysis: analysis[$0.0.id] ?? AssetAnalysis(), slot: $0.1) },
                               music: pool,
                               settings: DraftSettings(title: title, seed: seed, captions: noCaptions ? false : nil, music: noMusic ? false : nil,
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
    @Option(help: "Comma-separated: speech,transcript,loudness,faces,beats,events,visual") var kinds = "speech,transcript,faces"
    @Flag(help: "Print transcripts.") var transcript = false

    func run() async throws {
        let s = try Services(lib)
        let all = try s.library.assets().filter { !$0.tags.contains("music") }
        let selected = assets.isEmpty ? all : all.filter { a in assets.contains { a.name.localizedCaseInsensitiveContains($0) || a.id.uuidString.lowercased().hasPrefix($0.lowercased()) } }
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
    static let configuration = CommandConfiguration(abstract: "List templates or export them as editable JSON.")
    @OptionGroup var lib: LibraryOptions
    @Option(help: "Write every template as JSON into this folder.") var exportTo: String?

    func run() async throws {
        let s = try Services(lib)
        let all = try s.templates()
        if let dir = exportTo {
            let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for t in all { try ClipperJSON.encode(t).write(to: url.appendingPathComponent("\(t.id).json")) }
            Console.line("Wrote \(all.count) templates to \(url.path). Edit and pass with --template file.json, or save into the library's Templates/ folder.")
            return
        }
        Console.table([["ID", "NAME", "CANVAS", "SLOTS", "SUMMARY"]] + all.map {
            [$0.id, $0.name, "\($0.canvas.width)×\($0.canvas.height)@\($0.canvas.frameRate)", $0.slots.map(\.id).joined(separator: ","), $0.summary]
        })
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
