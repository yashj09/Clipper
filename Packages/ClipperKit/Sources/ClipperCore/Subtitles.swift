import Foundation

/// SRT / WebVTT / ASS sidecars from a timeline's caption items.
///
/// The plain sidecar (`<name>.srt`) carries the **visible** caption tracks, i.e. what is burned into the video.
/// Every caption track with a `language` additionally exports as `<name>.<language>.srt` — even when hidden, since
/// translated tracks are mostly delivered as sidecars rather than burned in.
public enum Subtitles {
    public struct Cue: Equatable, Sendable { public var start: Double; public var end: Double; public var text: String }

    /// A sidecar file's contents. `suffix` follows the export's base name: `"srt"` or `"es.srt"`.
    public struct Sidecar: Equatable, Sendable {
        public var suffix: String
        public var contents: String
    }

    /// Cues of the visible caption tracks.
    public static func cues(_ timeline: Timeline) -> [Cue] { cues(visibleTracks(timeline)) }

    /// Cues of every caption track tagged `language` (hidden or not).
    public static func cues(_ timeline: Timeline, language: String) -> [Cue] { cues(tracks(timeline, language: language)) }

    /// Languages of the timeline's caption tracks, unique, in track order.
    public static func languages(_ timeline: Timeline) -> [String] {
        var seen = Set<String>()
        return timeline.tracks.compactMap { $0.kind == .caption ? $0.language : nil }.filter { seen.insert($0).inserted }
    }

    public static func srt(_ timeline: Timeline) -> String { srt(cues(timeline)) }
    public static func vtt(_ timeline: Timeline) -> String { vtt(cues(timeline)) }

    public static func srt(_ cues: [Cue]) -> String {
        cues.enumerated().map { i, c in
            "\(i + 1)\n\(stamp(c.start, ",")) --> \(stamp(c.end, ","))\n\(c.text)\n"
        }.joined(separator: "\n")
    }

    public static func vtt(_ cues: [Cue]) -> String {
        "WEBVTT\n\n" + cues.map { c in "\(stamp(c.start, ".")) --> \(stamp(c.end, "."))\n\(c.text)\n" }.joined(separator: "\n")
    }

    /// Every sidecar to write for `formats`: the visible captions as `<ext>`, then `<language>.<ext>` per tagged language.
    /// `fontName` maps a style's PostScript font name to the name written into ASS styles (the Engine resolves it with
    /// Core Text; the default derives a full name from the PostScript name).
    public static func sidecars(_ timeline: Timeline, formats: [SidecarFormat],
                                fontName: (String) -> String = ASS.fullName(postScript:)) -> [Sidecar] {
        let visible = visibleTracks(timeline)
        var groups: [(prefix: String, tracks: [Track])] = [("", visible)]
        var used = Set<String>()
        for language in languages(timeline) {
            let tag = fileTag(language)
            guard used.insert(tag.lowercased()).inserted else { continue }
            let tagged = tracks(timeline, language: language)
            // Same tracks as the plain sidecar (e.g. English-only captions): don't write a duplicate file.
            if Set(tagged.map(\.id)) == Set(visible.map(\.id)) && languages(timeline).count == 1 { continue }
            groups.append(("\(tag).", tagged))
        }
        var out: [Sidecar] = []
        for format in formats {
            for group in groups {
                let cues = cues(group.tracks)
                guard !cues.isEmpty else { continue }
                let contents = switch format {
                case .srt: srt(cues)
                case .vtt: vtt(cues)
                case .ass: ass(timeline, tracks: group.tracks, fontName: fontName)
                }
                out.append(Sidecar(suffix: group.prefix + format.fileExtension, contents: contents))
            }
        }
        return out
    }

    /// A sidecar with distinct caption content and the language of its captions (nil = unknown).
    public struct SidecarLanguage: Equatable, Sendable {
        public var suffix: String
        public var language: String?
    }

    /// The `format` sidecars `sidecars(_:formats:)` names for this timeline that each carry distinct captions, with
    /// their language: every `<language>.<ext>` file, plus the plain `<ext>` file unless each of its (visible) tracks
    /// is already covered by a tagged file. The plain file is labelled with the visible tracks' language when they
    /// share one. Lets an uploader send each language once and label it correctly — e.g. Spanish-only captions are
    /// written only as `<name>.srt`, which must not be taken for English.
    public static func distinctSidecars(_ timeline: Timeline, format: SidecarFormat) -> [SidecarLanguage] {
        let visible = visibleTracks(timeline)
        let allLanguages = languages(timeline)
        var tagged: [SidecarLanguage] = []
        var taggedLanguages = Set<String>()
        var used = Set<String>()
        for language in allLanguages {
            let tag = fileTag(language)
            guard used.insert(tag.lowercased()).inserted else { continue }
            let tracks = tracks(timeline, language: language)
            // Mirrors `sidecars`: a single language identical to the visible tracks is only written as the plain file.
            if Set(tracks.map(\.id)) == Set(visible.map(\.id)) && allLanguages.count == 1 { continue }
            tagged.append(SidecarLanguage(suffix: "\(tag).\(format.fileExtension)", language: language))
            taggedLanguages.insert(language)
        }
        var out: [SidecarLanguage] = []
        let covered = !visible.isEmpty && visible.allSatisfy { $0.language.map(taggedLanguages.contains) ?? false }
        if !visible.isEmpty, !covered {
            let visibleLanguages = Set(visible.map(\.language))
            out.append(SidecarLanguage(suffix: format.fileExtension, language: visibleLanguages.count == 1 ? visibleLanguages.first! : nil))
        }
        return out + tagged
    }

    // MARK: - Internals

    static func visibleTracks(_ timeline: Timeline) -> [Track] {
        timeline.tracks.filter { $0.kind == .caption && !$0.hidden }
    }

    static func tracks(_ timeline: Timeline, language: String) -> [Track] {
        timeline.tracks.filter { $0.kind == .caption && $0.language == language }
    }

    static func cues(_ tracks: [Track]) -> [Cue] {
        tracks.flatMap { track in
            track.items.compactMap { item -> Cue? in
                guard case .caption(let c) = item.content, !c.words.isEmpty else { return nil }
                return Cue(start: item.start.seconds, end: item.end.seconds,
                           text: CaptionLanguage.join(c.words.map(\.text), language: track.language))
            }
        }
        .sorted { $0.start < $1.start }
    }

    /// A language tag reduced to characters that are safe in a file name.
    static func fileTag(_ tag: String) -> String {
        String(tag.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") ? $0 : "_" })
    }

    static func stamp(_ s: Double, _ sep: String) -> String {
        let ms = Int((s * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, sep, ms % 1000)
    }
}

/// Script facts about a caption language that change how words are joined and laid out.
public enum CaptionLanguage {
    /// Languages written without spaces between words.
    static let unspaced: Set<String> = ["zh", "ja", "th", "lo", "km", "my", "bo", "yue", "wuu"]
    static let rightToLeft: Set<String> = ["ar", "he", "iw", "fa", "ur", "ps", "yi", "sd", "ug", "dv", "ckb"]

    /// Primary language subtag, lowercased ("zh-Hant-TW" → "zh").
    public static func base(_ tag: String) -> String {
        tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() } ?? ""
    }

    /// False for Chinese, Japanese, Thai etc.; true when the language is unknown.
    public static func usesWordSpaces(_ tag: String?) -> Bool { tag.map { !unspaced.contains(base($0)) } ?? true }

    public static func isRightToLeft(_ tag: String?) -> Bool { tag.map { rightToLeft.contains(base($0)) } ?? false }

    /// A caption page's words as display text: space-separated, or run together for unspaced scripts.
    public static func join(_ words: [String], language: String?) -> String {
        words.joined(separator: usesWordSpaces(language) ? " " : "")
    }

    /// True when the first letter of `text` is in a right-to-left script (Hebrew, Arabic, Syriac, Thaana, N'Ko…).
    /// Used where the language isn't known, e.g. by the text renderer.
    public static func startsRightToLeft(_ text: some StringProtocol) -> Bool {
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            switch scalar.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF: return true
            default: return false
            }
        }
        return false
    }
}
