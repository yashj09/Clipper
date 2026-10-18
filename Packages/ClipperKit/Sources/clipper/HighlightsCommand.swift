import ArgumentParser
import ClipperAnalysis
import ClipperAutomation
import ClipperCore
import ClipperEngine
import ClipperLibrary
import Foundation

struct Highlights: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Find the best short-form moments in a long recording, then draft (and export) them as shorts.",
        discussion: """
        Examples:
          clipper highlights stream.mkv --top 10                      # ranked list
          clipper highlights podcast.mp4 --top 5 --draft --export     # 5 shorts, exported
          clipper highlights vod.mov --llm ollama --model qwen3:14b   # re-rank with a local LLM
        """)

    @OptionGroup var lib: LibraryOptions
    @Argument(help: "Long recording (or an already-imported asset name).") var file: String
    @Option(help: "How many highlights.") var top = 10
    @Option(help: "Minimum length (s).") var min: Double = 20
    @Option(help: "Maximum length (s).") var max: Double = 60
    @Option(help: "Preferred length (s).") var target: Double = 35
    @OptionGroup(title: "Local LLM re-ranking") var llm: LLMOptions
    @Option(name: .shortAndLong, help: "Template for the drafts.") var template = "talking-head"
    @Flag(help: "Create a project with one timeline per highlight.") var draft = false
    @Flag(help: "Export every drafted highlight (implies --draft).") var export = false
    @Option(help: "Export preset.") var preset: String?
    @Flag(help: "Disable music in drafts.") var noMusic = false
    @Flag(help: "Copy the recording into the library.") var copy = false

    func run() async throws {
        let s = try Services(lib)
        let start = ContinuousClock.now
        let asset = try await s.resolveOrImport(file, copy: copy)
        let template = try s.template(self.template)
        Console.line(String(format: "Recording: %@ (%.0f min)", asset.name, asset.info.duration.seconds / 60))

        var kinds: Set<AnalysisKind> = [.speech, .transcript, .events, .visual]
        kinds.formUnion(DraftPipeline.analysisKinds(for: template))
        let analysis = try await s.analyze([asset], kinds: kinds)[asset.id] ?? AssetAnalysis()
        let options = HighlightOptions(minDuration: min, maxDuration: max, targetDuration: target, count: top)
        var picks = HighlightFinder.find(analysis, duration: asset.info.duration.seconds, options: options)

        if let endpoint = try llm.endpoint() {
            let ranker = LocalLLMRanker(endpoint: endpoint)
            if await ranker.isAvailable() {
                // Give the model a wider pool than we keep, so it can promote good ones the heuristics underrated.
                let pool = HighlightFinder.select(HighlightFinder.candidates(analysis, duration: asset.info.duration.seconds, options: options), count: top * 3)
                Console.status("Ranking \(pool.count) candidates with \(endpoint.model)…")
                picks = Array(try await ranker.rank(pool, context: asset.name) { p in Console.progress(p, "LLM ranking") }.prefix(top))
                Console.clearStatus()
            } else {
                Console.line("⚠️ No local LLM at \(endpoint.baseURL.absoluteString); using heuristic ranking. (e.g. `ollama serve` + `ollama pull \(endpoint.model)`)")
            }
        }

        Console.line(String(format: "Found %d highlights in %.0fs:", picks.count, (ContinuousClock.now - start).seconds))
        var rows: [[String]] = [["#", "START", "LENGTH", "SCORE", "WHY", "OPENS WITH"]]
        for (i, h) in picks.enumerated() {
            let why: String = (h.title.map { "“\($0)” — " } ?? "") + h.reason
            let opening: String = String(h.text.prefix(48)) + (h.text.count > 48 ? "…" : "")
            rows.append([String(i + 1), HighlightFinder.clock(h.start), String(format: "%.0fs", h.duration), String(format: "%.2f", h.score), why, opening])
        }
        Console.table(rows)
        guard draft || export, !picks.isEmpty else { return }

        let pool = try s.musicPool()
        let sfx = try SoundEffects.ensure(in: s.library.soundEffectsURL)
        var timelines: [Timeline] = []
        for (i, h) in picks.enumerated() {
            let name = "\(i + 1). " + (h.title ?? String(h.text.split(separator: " ").prefix(6).joined(separator: " ")))
            let input = DraftInput(template: template,
                                   clips: [ClipInput(asset: asset, analysis: analysis, inPoint: h.start, outPoint: h.end)],
                                   music: pool,
                                   settings: DraftSettings(title: h.title, seed: UInt64(i + 1), music: noMusic ? false : nil, name: name),
                                   sfx: sfx)
            let result = DraftPipeline.run(input)
            for added in result.addedAssets { _ = try await s.library.importMedia([added.url], mode: .reference) { _ in added } }
            timelines.append(result.timeline)
        }
        let project = try s.library.saveProject(Project(name: "\(asset.name) highlights", timelines: timelines))
        Console.line("Saved project “\(project.name)” with \(timelines.count) shorts (\(project.id.uuidString.prefix(8)))")
        if export {
            for (i, tl) in timelines.enumerated() {
                Console.line("[\(i + 1)/\(timelines.count)] \(tl.name)")
                try await s.export(tl, project: project.name, preset: preset ?? template.exportPreset, to: nil)
            }
        }
    }

}

/// `--llm` / `--model`: which local OpenAI-compatible server to ask, shared by every command that can use one.
struct LLMOptions: ParsableArguments {
    @Option(help: "Local LLM: ollama, lmstudio, mlx, or a base URL like http://localhost:8080/v1.") var llm: String?
    @Option(help: "Model name for --llm.") var model: String?

    /// nil without `--llm`.
    func endpoint() throws -> LLMEndpoint? {
        guard let llm else { return nil }
        var endpoint: LLMEndpoint = switch llm.lowercased() {
        case "ollama": .ollama
        case "lmstudio", "lm-studio": .lmStudio
        case "mlx": .mlxServer
        default: LLMEndpoint(baseURL: try Self.serverURL(llm), model: model ?? "default")
        }
        if let model { endpoint.model = model }
        return endpoint
    }

    /// A `--llm` base URL: absolute http(s) with a host, e.g. http://localhost:8080/v1.
    static func serverURL(_ text: String) throws -> URL {
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else {
            throw ValidationErrorText("--llm must be ollama, lmstudio, mlx or a server URL like http://localhost:8080/v1 (got “\(text)”)")
        }
        return url
    }
}

/// Drafts new recordings as they appear in a folder.
struct Watch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Watch a folder and automatically draft (and export) new recordings.",
        discussion: "A file is processed once its size has been stable for two polls (so OBS/phone transfers can finish).")

    @OptionGroup var lib: LibraryOptions
    @Argument var folder: String
    @Option(name: .shortAndLong) var template = "talking-head"
    @Option(help: "Instead of one draft per file, cut this many highlights from each recording.") var highlights: Int?
    @Flag var export = false
    @Option var preset: String?
    @Option(help: "Seconds between polls.") var interval: Double = 5

    func run() async throws {
        let s = try Services(lib)
        let dir = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
        let exts: Set<String> = ["mov", "mp4", "m4v", "mkv", "webm"]
        var seen = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        var pending: [String: Int64] = [:]
        Console.line("Watching \(dir.path) (existing \(seen.count) files ignored). Ctrl-C to stop.")
        while !Task.isCancelled {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in names where !seen.contains(name) && exts.contains((name as NSString).pathExtension.lowercased()) {
                let path = dir.appendingPathComponent(name).path
                let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64) ?? -1
                if pending[name] == size, size > 0 {
                    seen.insert(name); pending[name] = nil
                    Console.line("New recording: \(name)")
                    do {
                        if let n = highlights {
                            var cmd = try Highlights.parse([path, "--top", String(n), "--template", template, "--draft"] + (export ? ["--export"] : []) + (preset.map { ["--preset", $0] } ?? []))
                            cmd.lib = lib
                            try await cmd.run()
                        } else {
                            var cmd = try Draft.parse(["--template", template, path] + (export ? ["--export"] : []) + (preset.map { ["--preset", $0] } ?? []))
                            cmd.lib = lib
                            try await cmd.run()
                        }
                    } catch { Console.line("  ⚠️ \(name): \(error)") }
                } else {
                    pending[name] = size
                }
            }
            try await Task.sleep(for: .seconds(interval))
        }
        _ = s
    }
}

extension Services {
    /// An existing asset by name/id prefix, or imports the file at `pathOrName`.
    func resolveOrImport(_ pathOrName: String, copy: Bool) async throws -> MediaAsset {
        let expanded = (pathOrName as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded) { return try await importFiles([expanded], copy: copy)[0] }
        let all = try library.assets()
        guard let a = all.first(where: { $0.name == pathOrName || $0.id.uuidString.lowercased().hasPrefix(pathOrName.lowercased()) }) else {
            throw ValidationErrorText("No such file or library asset: \(pathOrName)")
        }
        return a
    }
}
