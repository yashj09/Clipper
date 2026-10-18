import ArgumentParser
import ClipperAnalysis
import ClipperCore
import Foundation

struct Cover: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Pick a video's cover frame (sharp, well exposed, faces) and write it as a JPEG.")
    @OptionGroup var lib: LibraryOptions
    @Argument(help: "Asset name or id prefix.") var asset: String
    @Option(name: .shortAndLong, help: "JPEG to write. With --top N, frames go to <name>-1.jpg … <name>-N.jpg.")
    var output = "cover.jpg"
    @Option(help: "How many frames to write, best first.") var top = 1
    @Option(help: "Largest width of the written frames, in pixels.") var maxWidth = 1080

    func validate() throws {
        guard top >= 1 else { throw ValidationError("--top must be at least 1") }
        guard maxWidth >= 16 else { throw ValidationError("--max-width must be at least 16") }
    }

    func run() async throws {
        let s = try Services(lib)
        guard let a = try s.assets(matching: [asset]).first else { throw ValidationErrorText("No asset matches '\(asset)'") }
        guard a.info.kind == .video else { throw ValidationErrorText("\(a.name) is not a video") }
        guard let analysis = try await s.analyze([a], kinds: [.visual, .faces])[a.id] else { return }
        let rough = CoverFramePicker.candidates(analysis, count: 2 * top, duration: a.info.duration.seconds)
        guard !rough.isEmpty else { throw ValidationErrorText("No sampled frames in \(a.name)") }
        Console.status("Checking faces in \(rough.count) frames…")
        let ranked = try await CoverFramePicker.refine(url: a.renderURL, candidates: rough)
        Console.clearStatus()
        let base = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
        var rows = [["#", "TIME", "SCORE", "WHY", "FILE"]]
        for (i, c) in ranked.enumerated() {
            var written = ""
            if i < top {
                let file = top == 1 ? base : base.deletingLastPathComponent()
                    .appendingPathComponent("\(base.deletingPathExtension().lastPathComponent)-\(i + 1)")
                    .appendingPathExtension(base.pathExtension.isEmpty ? "jpg" : base.pathExtension)
                try await CoverFramePicker.export(url: a.renderURL, time: c.time, to: file, maxWidth: maxWidth)
                written = file.path
            }
            rows.append(["\(i + 1)", String(format: "%d:%05.2f", Int(c.time) / 60, c.time.truncatingRemainder(dividingBy: 60)),
                         String(format: "%.2f", c.score), c.reasons.joined(separator: ", "), written])
        }
        Console.table(rows)
    }
}
