import ArgumentParser
import ClipperCore
import ClipperLibrary
import Foundation

@main
struct Clipper: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clipper",
        abstract: "Local automatic video editor: import clips, draft a video from a template, export.",
        subcommands: [Draft.self, Highlights.self, Watch.self, Captions.self, Publish.self, Interchange.self, Import.self, Analyze.self, Export.self, Projects.self, Templates.self, MusicCommand.self,
                      Proxy.self, Presets.self, Info.self])
}

/// Options shared by every subcommand.
struct LibraryOptions: ParsableArguments {
    @Option(name: .long, help: "Path to a .clipperlib bundle (default: ~/Movies/Clipper/Clipper.clipperlib).")
    var library: String?

    var url: URL { library.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? Library.defaultURL }
}
