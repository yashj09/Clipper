import ArgumentParser
import ClipperAnalysis
import ClipperCore
import Foundation
import Translation

struct Captions: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Translate caption tracks (on-device, Apple Translation).",
                                                    subcommands: [Translate.self, Languages.self])

    static let common = ["es", "fr", "de", "it", "pt-BR", "hi", "ja", "ko", "zh-Hans", "ar", "ru", "tr", "id", "nl"]

    struct Languages: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show which caption languages are installed for on-device translation.")
        @Option(help: "Source language.") var from = "en"
        func run() async throws {
            let status = await CaptionTranslator.availability(from: Locale.Language(identifier: from),
                                                              to: Captions.common.map { Locale.Language(identifier: $0) })
            Console.table([["LANGUAGE", "STATUS"]] + Captions.common.map { code in
                let s = status[Locale.Language(identifier: code)]
                let text = switch s { case .installed: "installed"; case .supported: "download needed"; default: "unsupported" }
                return [code, text]
            })
            Console.line("Download languages in System Settings ▸ General ▸ Language & Region ▸ Translation Languages.")
        }
    }

    struct Translate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add translated caption tracks to a project (hidden; exported as <name>.<lang>.srt/vtt/ass).",
            discussion: "Example: clipper captions translate \"3 tips\" --to es,fr")
        @OptionGroup var lib: LibraryOptions
        @Argument(help: "Project name or id prefix.") var project: String
        @Option(help: "Comma-separated target languages.") var to: String
        @Option(help: "Translate only this timeline (default: all).") var timeline: Int?
        @Flag(help: "Show the first translated track instead of keeping it hidden.") var show = false

        func run() async throws {
            let s = try Services(lib)
            var p = try s.findProject(project)
            let targets = to.split(separator: ",").map { Locale.Language(identifier: String($0).trimmingCharacters(in: .whitespaces)) }
            let indices = timeline.map { [$0] } ?? Array(p.timelines.indices)
            for i in indices where p.timelines.indices.contains(i) {
                let source = p.timelines[i].tracks.first { $0.kind == .caption }?.language ?? "en"
                let translator = CaptionTranslator(source: Locale.Language(identifier: source))
                for target in targets {
                    Console.status("Translating “\(p.timelines[i].name)” → \(target.minimalIdentifier)…")
                    var tl = try await translator.addTranslatedTrack(to: p.timelines[i], target: target)
                    if show, let ti = tl.tracks.lastIndex(where: { $0.kind == .caption && $0.language == target.minimalIdentifier }) {
                        for j in tl.tracks.indices where tl.tracks[j].kind == .caption { tl.tracks[j].hidden = j != ti }
                    }
                    p.timelines[i] = tl
                    Console.clearStatus()
                    Console.line("  ✓ \(p.timelines[i].name): captions in \(target.minimalIdentifier)")
                }
            }
            _ = try s.library.saveProject(p)
            Console.line("Saved. Exports now include translated subtitle files" + (show ? " and burn in the shown language." : "."))
        }
    }
}
