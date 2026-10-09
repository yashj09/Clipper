import Foundation

/// SRT / WebVTT sidecars from a timeline's caption items.
public enum Subtitles {
    public struct Cue: Equatable, Sendable { public var start: Double; public var end: Double; public var text: String }

    public static func cues(_ timeline: Timeline) -> [Cue] {
        timeline.tracks.filter { $0.kind == .caption && !$0.hidden }
            .flatMap(\.items)
            .compactMap { item -> Cue? in
                guard case .caption(let c) = item.content, !c.words.isEmpty else { return nil }
                return Cue(start: item.start.seconds, end: item.end.seconds, text: c.text)
            }
            .sorted { $0.start < $1.start }
    }

    public static func srt(_ timeline: Timeline) -> String {
        cues(timeline).enumerated().map { i, c in
            "\(i + 1)\n\(stamp(c.start, ",")) --> \(stamp(c.end, ","))\n\(c.text)\n"
        }.joined(separator: "\n")
    }

    public static func vtt(_ timeline: Timeline) -> String {
        "WEBVTT\n\n" + cues(timeline).map { c in "\(stamp(c.start, ".")) --> \(stamp(c.end, "."))\n\(c.text)\n" }.joined(separator: "\n")
    }

    static func stamp(_ s: Double, _ sep: String) -> String {
        let ms = Int((s * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, sep, ms % 1000)
    }
}
