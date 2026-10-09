import ClipperCore

/// Refines ASR word edges against the loudness envelope (S3: Apple's SpeechTranscriber ends sentences 130–500 ms
/// early; snapping brings clean-speech boundary error to ~5 ms median).
public enum BoundarySnapper {
    /// Port of `snap()` in scripts/eval_asr.py, stepping one envelope hop at a time:
    /// - end inside voice → move forward while voiced (at most `maxExtendEnd`); end in silence → move back while silent.
    /// - start inside voice → move back while voiced (at most `maxExtendStart`); start in silence → move forward while silent.
    ///
    /// "Voiced" means the envelope frame is above `activity.threshold` *and* lies inside one of `activity.spans`
    /// (so isolated noise blips the detector dropped do not attract word edges). If the envelope is empty, spans alone
    /// decide. Guarantees: output is sorted by start (stable), `start <= end` for every word, and no word's end passes
    /// the next word's start (a word's start never moves back before the previous word's end).
    public static func snap(_ words: [TranscriptWord], activity: SpeechActivity,
                            maxExtendEnd: Double = 0.6, maxExtendStart: Double = 0.15) -> [TranscriptWord] {
        guard !words.isEmpty else { return [] }
        let probe = VoicingProbe(activity)
        let hop = probe.hop
        let endSteps = Int((maxExtendEnd / hop - 1e-6).rounded(.up))
        let startSteps = Int((maxExtendStart / hop - 1e-6).rounded(.up))

        let sorted = words.enumerated()
            .sorted { $0.element.start != $1.element.start ? $0.element.start < $1.element.start : $0.offset < $1.offset }
            .map(\.element)

        var out: [TranscriptWord] = []
        out.reserveCapacity(sorted.count)
        for (i, word) in sorted.enumerated() {
            let nextStart = i + 1 < sorted.count ? sorted[i + 1].start : .infinity
            let prevEnd = out.last?.end ?? -.infinity
            var s = max(word.start, prevEnd)
            var e = max(word.end, s)

            // End edge.
            if probe.voiced(e - hop / 2) {
                var k = 0
                while k < endSteps, e < nextStart, probe.voiced(e) { e += hop; k += 1 }
            } else {
                while e - hop > s, !probe.voiced(e - hop) { e -= hop }
            }
            e = max(s, min(e, nextStart))

            // Start edge.
            if probe.voiced(s + hop / 2) {
                let lower = max(prevEnd, 0)
                var k = 0
                while k < startSteps, s > lower, probe.voiced(s - hop) { s = max(s - hop, lower); k += 1 }
            } else {
                while s + hop < e, !probe.voiced(s) { s += hop }
            }
            s = min(max(s, prevEnd), e)

            var w = word
            w.start = s
            w.end = e
            out.append(w)
        }
        return out
    }
}

/// Answers "is time t voiced?" from a SpeechActivity.
struct VoicingProbe {
    let values: [Float]
    let hop: Double
    let threshold: Float
    let spans: [SpeechActivity.Span]

    init(_ activity: SpeechActivity) {
        values = activity.rms.values
        hop = activity.rms.hop > 0 ? activity.rms.hop : 0.01
        threshold = activity.threshold
        spans = activity.spans.sorted { $0.start < $1.start }
    }

    private static let eps = 1e-6

    func voiced(_ t: Double) -> Bool {
        if !values.isEmpty {
            let idx = Int((t / hop + Self.eps).rounded(.down))
            guard idx >= 0, idx < values.count, values[idx] > threshold else { return false }
        }
        return inSpan(t)
    }

    func inSpan(_ t: Double) -> Bool {
        let x = t + Self.eps
        // Last span with start <= x.
        var lo = 0, hi = spans.count
        while lo < hi {
            let m = (lo + hi) / 2
            if spans[m].start <= x { lo = m + 1 } else { hi = m }
        }
        guard lo > 0 else { return false }
        return x < spans[lo - 1].end
    }
}
