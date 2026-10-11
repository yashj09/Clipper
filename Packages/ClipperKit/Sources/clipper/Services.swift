import ClipperAnalysis
import ClipperAutomation
import ClipperCore
import ClipperEngine
import ClipperLibrary
import Foundation

/// The CLI's wiring of library + engine + analysis + automation (the app wires the same pieces).
struct Services {
    let library: Library

    init(_ options: LibraryOptions) throws {
        library = try Library.openOrCreate(at: options.url)
    }

    var transcodeDirectory: URL { library.mediaURL.appendingPathComponent("Transcoded", isDirectory: true) }

    /// Imports files (or returns already-imported assets with the same content), transcoding unreadable formats.
    func importFiles(_ paths: [String], copy: Bool) async throws -> [MediaAsset] {
        let urls = try paths.map { p -> URL in
            let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else { throw ValidationErrorText("No such file: \(p)") }
            return url
        }
        let dir = transcodeDirectory
        var out: [MediaAsset] = []
        for url in urls {
            Console.status("Importing \(url.lastPathComponent)…")
            out += try await library.importMedia([url], mode: copy ? .copy : .reference) { u in
                try await Transcoder.makeAsset(u, transcodeDirectory: dir)
            }
        }
        Console.clearStatus()
        return out
    }

    func assetMap() throws -> [AssetID: MediaAsset] {
        Dictionary(uniqueKeysWithValues: try library.assets().map { ($0.id, $0) })
    }

    /// Runs (or loads from cache) the analyses a template needs for each clip.
    func analyze(_ assets: [MediaAsset], kinds: Set<AnalysisKind>) async throws -> [AssetID: AssetAnalysis] {
        let settings = try library.settings()
        let options = AnalysisOptions(locale: Locale(identifier: settings.automation.transcriptionLocale))
        let pipeline = AnalysisPipeline(cache: library.analysisCache, options: options)
        var result: [AssetID: AssetAnalysis] = [:]
        for (i, asset) in assets.enumerated() {
            let label = "[\(i + 1)/\(assets.count)] \(asset.name)"
            let start = ContinuousClock.now
            result[asset.id] = try await pipeline.analyze(asset, kinds: kinds) { kind, fraction in
                Console.status("Analyzing \(label): \(kind.rawValue) \(Int(fraction * 100))%")
            }
            Console.clearStatus()
            let a = result[asset.id]!
            var parts: [String] = []
            if let t = a.transcript { parts.append("\(t.words.count) words") }
            if let s = a.speech { parts.append(String(format: "%.0fs speech", s.spans.reduce(0) { $0 + $1.duration })) }
            if let f = a.faces { parts.append("\(f.samples.count) face samples") }
            Console.line(String(format: "  ✓ %@ (%@) %.1fs", asset.name, parts.joined(separator: ", "), (ContinuousClock.now - start).seconds))
        }
        return result
    }

    /// Which analyses a template's rules depend on.
    static func kinds(for template: Template) -> Set<AnalysisKind> {
        var k: Set<AnalysisKind> = []
        if template.rules.silenceCut != nil || template.rules.captions != nil || template.rules.duck != nil { k.formUnion([.speech, .transcript]) }
        if template.slots.contains(where: { $0.reframe == .face }) { k.insert(.faces) }
        return k
    }

    func templates() throws -> [Template] { BuiltIns.templates + (try library.userTemplates()) }

    func template(_ idOrPath: String) throws -> Template {
        if idOrPath.hasSuffix(".json") {
            return try ClipperJSON.decode(Template.self, from: Data(contentsOf: URL(fileURLWithPath: (idOrPath as NSString).expandingTildeInPath)))
        }
        guard let t = try templates().first(where: { $0.id == idOrPath }) else {
            throw ValidationErrorText("Unknown template '\(idOrPath)'. Try: \(try templates().map(\.id).joined(separator: ", "))")
        }
        return t
    }

    /// Music tracks whose files still exist.
    func musicPool() throws -> [MusicTrack] {
        try library.music().filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    func findProject(_ query: String) throws -> Project {
        let all = try library.projects()
        if let id = UUID(uuidString: query), all.contains(where: { $0.id == id }) { return try library.loadProject(id) }
        let matches = all.filter { $0.id.uuidString.lowercased().hasPrefix(query.lowercased()) || $0.name.localizedCaseInsensitiveContains(query) }
        guard let first = matches.first else { throw ValidationErrorText("No project matches '\(query)'") }
        if matches.count > 1 { Console.line("Several projects match; using the most recent: \(first.name)") }
        return try library.loadProject(first.id)
    }

    /// Exports one timeline, printing a progress bar. Returns the output URL.
    @discardableResult
    func export(_ timeline: Timeline, project: String, preset presetID: String?, to path: String?) async throws -> URL {
        let settings = try library.settings()
        guard let preset = ExportPreset.named(presetID ?? settings.export.defaultPreset) else {
            throw ValidationErrorText("Unknown preset. Try: \(ExportPreset.builtIn.map(\.id).joined(separator: ", "))")
        }
        let url: URL
        if let path { url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        else {
            let name = settings.export.fileNamePattern.replacingOccurrences(of: "{project}", with: project)
                .replacingOccurrences(of: "{timeline}", with: timeline.name).replacingOccurrences(of: "/", with: "-")
            url = try library.exportFolder().appendingPathComponent(name).appendingPathExtension(preset.container.fileExtension)
        }
        let assets = try assetMap()
        Console.line("Exporting \(preset.name) → \(url.path)")
        let result = try await Exporter.export(timeline, assets: assets, preset: preset, to: url) { p in
            Console.progress(p.fraction, String(format: "%.0f fps", p.framesPerSecond))
        }
        Console.clearStatus()
        var line = String(format: "  ✓ %d frames in %.1fs (%.0f fps)", result.frames, result.seconds, Double(result.frames) / max(result.seconds, 0.001))
        if let g = result.appliedGain { line += String(format: ", loudness %+.1f dB → %.0f LUFS", g, preset.loudness ?? 0) }
        Console.line(line)
        for s in result.sidecars { Console.line("  ✓ \(s.lastPathComponent)") }
        if !timeline.attributions.isEmpty {
            Console.line("  Credits (include in your description):")
            timeline.attributions.forEach { Console.line("    \($0)") }
        }
        return url
    }
}

struct ValidationErrorText: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// Minimal terminal output: results on stdout, live status on stderr.
enum Console {
    nonisolated(unsafe) static var statusShown = false
    static let isTTY = isatty(STDERR_FILENO) == 1

    static func line(_ s: String) {
        clearStatus()
        print(s)
    }

    static func status(_ s: String) {
        guard isTTY else { return }
        FileHandle.standardError.write(Data("\r\u{1B}[2K\(s.prefix(110))".utf8))
        statusShown = true
    }

    static func progress(_ fraction: Double, _ detail: String) {
        let width = 30, filled = Int((fraction * Double(width)).rounded())
        status("[\(String(repeating: "█", count: filled))\(String(repeating: "░", count: max(0, width - filled)))] \(Int(fraction * 100))% \(detail)")
    }

    static func clearStatus() {
        guard statusShown else { return }
        FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8))
        statusShown = false
    }

    static func table(_ rows: [[String]]) {
        guard let first = rows.first else { return }
        let widths = (0..<first.count).map { c in rows.map { $0.count > c ? $0[c].count : 0 }.max() ?? 0 }
        for r in rows { line(r.enumerated().map { $0.element.padding(toLength: widths[$0.offset], withPad: " ", startingAt: 0) }.joined(separator: "  ")) }
    }
}
