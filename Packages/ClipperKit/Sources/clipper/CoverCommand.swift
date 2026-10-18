import ArgumentParser
import ClipperAnalysis
import ClipperCore
import ClipperEngine
import Foundation

struct Cover: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Pick a cover frame (sharp, well exposed, faces) of a project or a video and write it as a JPEG.",
        discussion: """
        A project's cover is rendered like its export (captions, titles, colour) and prefers frames with a caption on
        screen. Projects are matched first, then assets.
        """)
    @OptionGroup var lib: LibraryOptions
    @Argument(help: "Project or asset name, or id prefix.") var name: String
    @Option(help: "Timeline index within the project.") var timeline = 0
    @Option(name: .shortAndLong, help: """
        JPEG to write (default: <project>-cover.jpg, or cover.jpg for an asset). With --top N, frames go to \
        <name>-1.jpg … <name>-N.jpg.
        """)
    var output: String?
    @Option(help: "How many frames to write, best first.") var top = 1
    @Option(help: "Largest width of the written frames, in pixels.") var maxWidth = 1080

    func validate() throws {
        guard top >= 1 else { throw ValidationError("--top must be at least 1") }
        guard maxWidth >= 16 else { throw ValidationError("--max-width must be at least 16") }
    }

    func run() async throws {
        let s = try Services(lib)
        if let project = try? s.findProject(name) {
            try await cover(project, s)
        } else {
            try await cover(asset: s)
        }
    }

    func cover(_ project: Project, _ s: Services) async throws {
        guard project.timelines.indices.contains(timeline) else { throw ValidationErrorText("Project has \(project.timelines.count) timeline(s)") }
        let tl = project.timelines[timeline]
        let assets = try s.assetMap()
        var seen = Set<AssetID>()
        let clips = (tl.tracks.first { $0.kind == .video }?.items ?? []).compactMap { $0.content.mediaRef?.asset }
            .filter { seen.insert($0).inserted }.compactMap { assets[$0] }.filter { $0.info.kind == .video }
        Console.line("Project “\(project.name)”, timeline “\(tl.name)”")
        let analyses = try await s.analyze(clips, kinds: [.visual, .faces])
        let picked = TimelineCover.pick(timeline: tl, analyses: analyses, count: top)
        guard !picked.isEmpty else { throw ValidationErrorText("No sampled frames on the timeline of \(project.name)") }
        try await write(picked, default: "\(project.name.replacingOccurrences(of: "/", with: "-"))-cover.jpg") { c, file in
            try StillRenderer.writeJPEG(try await Exporter.renderFrame(tl, assets: assets, at: RationalTime(seconds: c.time), maxWidth: maxWidth),
                                        to: file)
        }
    }

    func cover(asset s: Services) async throws {
        guard let a = try s.assets(matching: [name]).first else { throw ValidationErrorText("No project or asset matches '\(name)'") }
        guard a.info.kind == .video else { throw ValidationErrorText("\(a.name) is not a video") }
        guard let analysis = try await s.analyze([a], kinds: [.visual, .faces])[a.id] else { return }
        let rough = CoverFramePicker.candidates(analysis, count: 2 * top, duration: a.info.duration.seconds)
        guard !rough.isEmpty else { throw ValidationErrorText("No sampled frames in \(a.name)") }
        Console.status("Checking faces in \(rough.count) frames…")
        let ranked = try await CoverFramePicker.refine(url: a.renderURL, candidates: rough)
        Console.clearStatus()
        try await write(ranked, default: "cover.jpg") { c, file in
            try await CoverFramePicker.export(url: a.renderURL, time: c.time, to: file, maxWidth: maxWidth)
        }
    }

    /// Writes the best `top` candidates with `writeFrame` and prints every candidate.
    func write(_ ranked: [CoverCandidate], default name: String,
               _ writeFrame: (CoverCandidate, URL) async throws -> Void) async throws {
        let base = URL(fileURLWithPath: ((output ?? name) as NSString).expandingTildeInPath)
        var rows = [["#", "TIME", "SCORE", "WHY", "FILE"]]
        for (i, c) in ranked.enumerated() {
            var written = ""
            if i < top {
                let file = top == 1 ? base : base.deletingLastPathComponent()
                    .appendingPathComponent("\(base.deletingPathExtension().lastPathComponent)-\(i + 1)")
                    .appendingPathExtension(base.pathExtension.isEmpty ? "jpg" : base.pathExtension)
                try await writeFrame(c, file)
                written = file.path
            }
            rows.append(["\(i + 1)", String(format: "%d:%05.2f", Int(c.time) / 60, c.time.truncatingRemainder(dividingBy: 60)),
                         String(format: "%.2f", c.score), c.reasons.joined(separator: ", "), written])
        }
        Console.table(rows)
    }
}
