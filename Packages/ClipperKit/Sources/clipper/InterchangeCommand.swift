import ArgumentParser
import ClipperCore
import ClipperPublish
import Foundation

struct Interchange: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Hand a timeline to Final Cut Pro / DaVinci Resolve (FCPXML) or any OpenTimelineIO tool (.otio).",
        discussion: "Example: clipper interchange \"3 tips\" --format fcpxml -o ~/Desktop/3-tips.fcpxml   (Resolve: use --fcpxml-version 1.10 if 1.11 is rejected)")
    @OptionGroup var lib: LibraryOptions
    @Argument(help: "Project name or id prefix.") var project: String
    @Option var timeline = 0
    @Option(help: "fcpxml or otio") var format = "fcpxml"
    @Option(help: "FCPXML version: 1.11 or 1.10.") var fcpxmlVersion = "1.11"
    @Option(help: "Captions in FCPXML: captions, titles or omit.") var captions = "captions"
    @Option(name: .shortAndLong) var output: String?

    func run() async throws {
        let s = try Services(lib)
        let p = try s.findProject(project)
        guard p.timelines.indices.contains(timeline) else { throw ValidationErrorText("Project has \(p.timelines.count) timeline(s)") }
        let tl = p.timelines[timeline]
        let assets = try s.assetMap()
        let data: Data
        let ext: String
        switch format.lowercased() {
        case "fcpxml":
            var exporter = FCPXMLExporter(version: fcpxmlVersion == "1.10" ? .v1_10 : .v1_11, projectName: tl.name)
            exporter.captionMode = captions == "titles" ? .titles : captions == "omit" ? .omit : .captions
            data = try exporter.export(tl, assets: assets)
            ext = "fcpxml"
        case "otio":
            data = try OTIOExporter().export(tl, assets: assets)
            ext = "otio"
        default:
            throw ValidationErrorText("Format must be fcpxml or otio")
        }
        let fallbackName = ext == "otio" ? OTIOExporter.suggestedFileName(projectName: tl.name) : FCPXMLExporter.suggestedFileName(projectName: tl.name)
        let defaultURL = try s.library.exportFolder().appendingPathComponent(fallbackName)
        let url = output.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? defaultURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        if format == "fcpxml", !Subtitles.cues(tl).isEmpty {
            try FCPXMLExporter.captionsSRT(tl).write(to: url.deletingPathExtension().appendingPathExtension("srt"), atomically: true, encoding: .utf8)
        }
        Console.line("Wrote \(url.path)" + (format == "fcpxml" ? " (+ .srt captions for Resolve). Open with Final Cut Pro (File ▸ Import ▸ XML) or Resolve (File ▸ Import ▸ Timeline)." : ""))
    }
}
