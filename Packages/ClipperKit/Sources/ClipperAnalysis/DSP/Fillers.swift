import ClipperCore
import Foundation

public enum Fillers {
    /// Canonical filler forms after lowercasing, stripping non-letters and collapsing repeated letters
    /// ("Ummm," → "um", "hmm" → "hm", "mm" → "m", "errr" → "er").
    static let canonical: Set<String> = ["um", "uh", "er", "erm", "ah", "hm", "m", "uhm"]

    /// Lexical fillers ("um", "uh", "er", "erm", "ah", "hmm", "mm", "uhm"), punctuation- and case-insensitive.
    /// Drawn-out spellings ("ummm", "uhhh") also count.
    public static func isFiller(_ word: String) -> Bool {
        var collapsed = String.UnicodeScalarView()
        var last: Unicode.Scalar?
        for c in word.lowercased().unicodeScalars where CharacterSet.letters.contains(c) {
            if c != last { collapsed.append(c) }
            last = c
        }
        guard !collapsed.isEmpty else { return false }
        return canonical.contains(String(collapsed))
    }

    /// Sets `isFiller` on lexical fillers (words already flagged stay flagged).
    public static func markFillers(_ words: [TranscriptWord]) -> [TranscriptWord] {
        words.map { w in
            var w = w
            w.isFiller = w.isFiller || isFiller(w.text)
            return w
        }
    }

    /// Voiced stretches ≥ `minDuration` (default 0.2 s) that contain no transcribed word — likely untranscribed
    /// fillers/breaths. Each activity span has the union of word intervals subtracted from it; the remaining pieces
    /// that are long enough are returned, in time order. Pass *snapped* words (see `BoundarySnapper`): raw ASR ends
    /// are early and would leave false voiced remainders at sentence ends.
    public static func unworded(activity: SpeechActivity, words: [TranscriptWord],
                                minDuration: Double = 0.2) -> [SpeechActivity.Span] {
        // Union of word intervals.
        var covered: [(Double, Double)] = []
        for w in words.sorted(by: { $0.start < $1.start }) where w.end > w.start {
            if let last = covered.last, w.start <= last.1 {
                covered[covered.count - 1].1 = max(last.1, w.end)
            } else {
                covered.append((w.start, w.end))
            }
        }
        let eps = 1e-9
        var result: [SpeechActivity.Span] = []
        var j = 0
        for span in activity.spans.sorted(by: { $0.start < $1.start }) {
            while j < covered.count && covered[j].1 <= span.start { j += 1 }
            var cursor = span.start
            var k = j
            while k < covered.count && covered[k].0 < span.end {
                if covered[k].0 > cursor, covered[k].0 - cursor >= minDuration - eps {
                    result.append(.init(start: cursor, end: covered[k].0))
                }
                cursor = max(cursor, covered[k].1)
                k += 1
            }
            if span.end - cursor >= minDuration - eps {
                result.append(.init(start: cursor, end: span.end))
            }
        }
        return result
    }
}
