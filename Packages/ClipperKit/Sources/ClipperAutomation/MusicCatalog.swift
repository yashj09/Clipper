import ClipperCore
import Foundation

/// Canonical moods used by templates, and mapping from source vocabularies (e.g. Incompetech "feel" tags).
public enum Mood {
    public static let canonical = ["chill", "upbeat", "happy", "inspiring", "energetic", "intense", "cinematic", "dark", "funny", "mysterious"]

    /// Incompetech "feel" → canonical moods.
    static let incompetech: [String: [String]] = [
        "relaxed": ["chill"], "calming": ["chill"], "grooving": ["chill", "upbeat"],
        "bright": ["happy", "upbeat"], "bouncy": ["upbeat", "happy"], "humorous": ["funny", "happy"],
        "uplifting": ["inspiring", "happy"], "epic": ["cinematic", "inspiring"],
        "driving": ["energetic"], "action": ["energetic", "intense"], "intense": ["intense", "energetic"], "aggressive": ["intense"],
        "dark": ["dark"], "somber": ["dark", "cinematic"], "eerie": ["dark", "mysterious"], "unnerving": ["dark"],
        "mysterious": ["mysterious", "cinematic"], "mystical": ["mysterious", "cinematic"], "suspenseful": ["cinematic", "intense"],
    ]

    public static func fromIncompetech(feel: String) -> [String] {
        var out: [String] = []
        for tag in feel.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
            for m in incompetech[tag] ?? [] where !out.contains(m) { out.append(m) }
        }
        return out
    }
}

/// The Incompetech catalog (`https://incompetech.com/music/royalty-free/pieces.json`), CC BY 4.0.
public enum IncompetechCatalog {
    public static let catalogURL = URL(string: "https://incompetech.com/music/royalty-free/pieces.json")!

    public struct Piece: Decodable, Sendable {
        public var title: String
        public var filename: String
        public var length: String
        public var bpm: String?
        public var feel: String?
        public var instruments: String?

        public var seconds: Double {
            let parts = length.split(separator: ":").compactMap { Double($0) }
            return parts.reduce(0) { $0 * 60 + $1 }
        }
        /// `filename` when it is safe to use as a file name in the library: the catalog is remote data, so anything with
        /// a path separator, a leading dot ("..", hidden files) or control characters is refused (nil).
        public var localFileName: String? {
            let unsafe = filename.isEmpty || filename.utf8.count > 255 || filename.hasPrefix(".")
                || filename.contains { $0 == "/" || $0 == "\\" || $0 == ":" || $0.unicodeScalars.contains { $0.properties.generalCategory == .control } }
            return unsafe ? nil : filename
        }

        /// Where the MP3 is downloaded from (nil when the catalog's file name is unsafe or can't form a URL).
        public var downloadURL: URL? {
            guard let file = localFileName,
                  let name = file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "'&?#")))
            else { return nil }
            return URL(string: "https://incompetech.com/music/royalty-free/mp3-royaltyfree/\(name)")
        }
        /// The attribution text the licence requires.
        public var attribution: String {
            "\"\(title)\" Kevin MacLeod (incompetech.com) — Licensed under Creative Commons: By Attribution 4.0 License, http://creativecommons.org/licenses/by/4.0/"
        }
        public var moods: [String] { Mood.fromIncompetech(feel: feel ?? "") }

        public func track(localURL: URL) -> MusicTrack {
            MusicTrack(id: "incompetech:\(title)", title: title, artist: "Kevin MacLeod", url: localURL, duration: seconds,
                       license: .ccBy(attribution: attribution), moods: moods, bpm: bpm.flatMap(Double.init))
        }
    }

    public static func decode(_ data: Data) throws -> [Piece] { try JSONDecoder().decode([Piece].self, from: data) }

    /// A balanced starter pack: `perMood` tracks for each template mood, 90 s–4 min long, sensible tempos,
    /// chosen deterministically (stable across runs) so everyone with the same catalog gets the same pack.
    public static func starterPack(_ pieces: [Piece], moods: [String] = ["chill", "upbeat", "happy", "inspiring", "energetic", "cinematic"],
                                   perMood: Int = 4) -> [Piece] {
        var chosen: [Piece] = []
        var used = Set<String>()
        for mood in moods {
            let candidates = pieces
                .filter { (90...240).contains($0.seconds) && $0.moods.contains(mood) && !used.contains($0.title) }
                .filter { $0.downloadURL != nil }
                // Keep dark/eerie pieces out of the light moods.
                .filter { ["cinematic", "mysterious", "dark", "intense"].contains(mood) || !$0.moods.contains("dark") }
                .filter { p in p.bpm.flatMap(Double.init).map { (70...150).contains($0) } ?? false }
                .sorted { (stableHash($0.title), $0.title) < (stableHash($1.title), $1.title) }
            for p in candidates.prefix(perMood) { chosen.append(p); used.insert(p.title) }
        }
        return chosen
    }
}
