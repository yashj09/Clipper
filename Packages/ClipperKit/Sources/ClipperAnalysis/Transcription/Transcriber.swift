import ClipperCore
import Foundation

/// A speech-to-text engine producing word-level timings.
///
/// Implementations return *raw* engine timings: word times are seconds in the source file's timeline (a `range`
/// offset is already added), but edges are not refined. `AnalysisPipeline` snaps them to the loudness envelope
/// (`BoundarySnapper`) and marks fillers.
public protocol Transcriber: Sendable {
    /// Stable engine identifier, stored in `Transcript.engine` and used in analysis cache keys
    /// (include anything that changes the output, such as the model).
    var id: String { get }
    /// Transcribes the audio of any AVFoundation-readable file (audio or video).
    /// - Parameter range: optional part of the source to transcribe, in seconds.
    func transcribe(url: URL, locale: Locale, range: ClosedRange<Double>?) async throws -> Transcript
}

public enum TranscriptionError: Error, Sendable, CustomStringConvertible {
    case unsupportedLocale(String)
    case unavailable(String)
    case failed(String)

    public var description: String {
        switch self {
        case .unsupportedLocale(let id): "Speech recognition does not support the locale \(id)"
        case .unavailable(let why): "Speech recognition unavailable: \(why)"
        case .failed(let why): "Transcription failed: \(why)"
        }
    }
}

enum WordSplitter {
    /// Splits a recognized run that may hold several space-separated tokens into words, dividing the run's time span
    /// in proportion to each token's character count (a single token keeps the whole span).
    static func split(_ text: String, start: Double, end: Double, confidence: Double?) -> [TranscriptWord] {
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !parts.isEmpty else { return [] }
        guard parts.count > 1 else { return [TranscriptWord(text: parts[0], start: start, end: end, confidence: confidence)] }
        let total = Double(parts.reduce(0) { $0 + max(1, $1.count) })
        let span = max(0, end - start)
        var words: [TranscriptWord] = []
        var cursor = start
        for (i, p) in parts.enumerated() {
            let e = i == parts.count - 1 ? end : cursor + span * Double(max(1, p.count)) / total
            words.append(TranscriptWord(text: p, start: cursor, end: e, confidence: confidence))
            cursor = e
        }
        return words
    }
}
