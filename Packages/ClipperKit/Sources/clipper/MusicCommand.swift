import ArgumentParser
import ClipperAnalysis
import ClipperAutomation
import ClipperCore
import ClipperLibrary
import CryptoKit
import Foundation

struct MusicCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "music", abstract: "Manage the music library.",
                                                    subcommands: [List.self, Add.self, StarterPack.self, Generate.self])

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List music with tempo, moods and licence.")
        @OptionGroup var lib: LibraryOptions
        func run() async throws {
            let tracks = try Services(lib).library.music()
            Console.table([["ID", "TITLE", "BPM", "LENGTH", "MOODS", "LICENCE"]] + tracks.map { t in
                let license: String = switch t.license { case .ccBy: "CC BY"; case .cc0: "CC0"; case .owned: "own"; case .generated: "generated" }
                return [t.id.count > 28 ? String(t.id.prefix(28)) + "…" : t.id, t.title, t.bpm.map { String(format: "%.0f", $0) } ?? "-",
                        String(format: "%d:%02d", Int(t.duration) / 60, Int(t.duration) % 60), t.moods.joined(separator: ","), license]
            })
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add your own music files or folders (tempo and beats are analyzed).")
        @OptionGroup var lib: LibraryOptions
        @Argument var paths: [String]
        @Option(help: "Comma-separated moods for these tracks (\(Mood.canonical.joined(separator: ", "))).") var moods = ""
        @Option(help: "Licence: own, cc0, or 'ccby:<attribution text>'.") var license = "own"

        func run() async throws {
            let s = try Services(lib)
            let exts: Set<String> = ["mp3", "m4a", "wav", "aiff", "aif", "caf", "flac", "aac"]
            var files: [URL] = []
            for p in paths {
                let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
                    while let f = e?.nextObject() as? URL { if exts.contains(f.pathExtension.lowercased()) { files.append(f) } }
                } else { files.append(url) }
            }
            let lic: MusicLicense = license == "cc0" ? .cc0 : license.hasPrefix("ccby:") ? .ccBy(attribution: String(license.dropFirst(5))) : .owned
            let moodList = moods.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            var tracks: [MusicTrack] = []
            for (i, f) in files.enumerated() {
                Console.status("Analyzing [\(i + 1)/\(files.count)] \(f.lastPathComponent)")
                let a = try await MusicAnalyzer.analyze(url: f)
                let id = "file:" + SHA256.hash(data: Data(f.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
                tracks.append(MusicTrack(id: id, title: f.deletingPathExtension().lastPathComponent, artist: "", url: f, duration: a.duration,
                                         license: lic, moods: moodList, bpm: a.beats.bpm > 0 ? a.beats.bpm : nil, energy: a.energy, beats: a.beats))
            }
            try s.library.upsertMusic(tracks)
            Console.line("Added \(tracks.count) track(s).")
        }
    }

    struct StarterPack: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "starter-pack",
            abstract: "Download a free 24-track pack (Kevin MacLeod, incompetech.com, CC BY 4.0) and analyze it.",
            discussion: "Tracks are CC BY 4.0: Clipper adds the required credit to each project that uses one; include it in your video description.")
        @OptionGroup var lib: LibraryOptions
        @Option(help: "Tracks per mood (6 moods).") var perMood = 4

        func run() async throws {
            let s = try Services(lib)
            Console.status("Fetching catalog…")
            let (data, _) = try await URLSession.shared.data(from: IncompetechCatalog.catalogURL)
            let pieces = IncompetechCatalog.starterPack(try IncompetechCatalog.decode(data), perMood: perMood)
            let dir = s.library.url.appendingPathComponent("Music/Incompetech", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var tracks: [MusicTrack] = []
            for (i, p) in pieces.enumerated() {
                let file = dir.appendingPathComponent(p.filename)
                if !FileManager.default.fileExists(atPath: file.path) {
                    Console.status("Downloading [\(i + 1)/\(pieces.count)] \(p.title)")
                    let (tmp, response) = try await URLSession.shared.download(from: p.downloadURL)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { Console.line("  ⚠️ \(p.title): download failed"); continue }
                    try FileManager.default.moveItem(at: tmp, to: file)
                }
                Console.status("Analyzing [\(i + 1)/\(pieces.count)] \(p.title)")
                let a = try await MusicAnalyzer.analyze(url: file)
                var t = p.track(localURL: file)
                t.duration = a.duration
                t.beats = a.beats
                t.energy = a.energy
                if a.beats.bpm > 0 { t.bpm = a.beats.bpm }
                tracks.append(t)
            }
            try s.library.upsertMusic(tracks)
            Console.line("Added \(tracks.count) tracks to \(dir.path)")
        }
    }

    struct Generate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Generate royalty-free instrumental music on this Mac (ACE-Step 1.5, MIT) and add it to the library.",
            discussion: """
            Needs the optional Python worker (uv + `worker/`); the first run downloads ~6.3 GB of model weights.
            Example: clipper music generate "upbeat lo-fi hip hop, warm keys" --duration 60 --bpm 90 --variations 2
            """)
        @OptionGroup var lib: LibraryOptions
        @Argument(help: "Describe the music (genre, mood, instruments).") var prompt: String
        @Option(help: "Length in seconds.") var duration: Double = 60
        @Option(help: "Tempo hint.") var bpm: Double?
        @Option(help: "How many different takes.") var variations = 1
        @Option(help: "First seed.") var seed = 0
        @Option(help: "Comma-separated moods (default: inferred from the prompt).") var moods: String?

        func run() async throws {
            let s = try Services(lib)
            guard let generator = MusicGenerator.makeDefault() else {
                throw ValidationErrorText("Music generation needs uv (brew install uv) and the worker project (set CLIPPER_WORKER_DIR to the repo's worker/ folder).")
            }
            defer { Task { await generator.worker.shutdown() } }
            let out = s.library.url.appendingPathComponent("Music/Generated", isDirectory: true)
            let moodList = moods.map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() } }
            var tracks: [MusicTrack] = []
            for v in 0..<max(1, variations) {
                let start = ContinuousClock.now
                let track = try await generator.generate(prompt: prompt, duration: duration, bpm: bpm, seed: seed + v,
                                                         outputDirectory: out, moods: moodList) { p in
                    Console.progress(p.fraction, "take \(v + 1)/\(variations) " + (p.message ?? ""))
                }
                Console.clearStatus()
                Console.line(String(format: "  ✓ %@ — %.0fs, %@ BPM, moods %@ (%.0fs)", track.title, track.duration,
                                    track.bpm.map { String(format: "%.0f", $0) } ?? "?", track.moods.joined(separator: ","),
                                    (ContinuousClock.now - start).seconds))
                tracks.append(track)
            }
            try s.library.upsertMusic(tracks)
            await generator.worker.shutdown()
            Console.line("Added \(tracks.count) generated track(s) to the music library (licence: generated, no attribution needed).")
        }
    }
}
