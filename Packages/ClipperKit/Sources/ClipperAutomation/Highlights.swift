import ClipperCore
import Foundation

/// Finds short-form candidates in a long recording from analysis signals alone (no AI needed).
/// Candidates start and end on sentence boundaries; each gets a transparent score built from named signals,
/// and the best non-overlapping ones are returned. An optional local LLM can re-rank them afterwards.
public struct HighlightOptions: Sendable, Equatable {
    public var minDuration: Double
    public var maxDuration: Double
    /// Preferred length; candidates far from it are penalized.
    public var targetDuration: Double
    public var count: Int
    public init(minDuration: Double = 20, maxDuration: Double = 60, targetDuration: Double = 35, count: Int = 10) {
        self.minDuration = minDuration; self.maxDuration = maxDuration; self.targetDuration = targetDuration; self.count = count
    }
}

public enum HighlightFinder {
    public static func find(_ analysis: AssetAnalysis, duration: Double, options: HighlightOptions = HighlightOptions()) -> [Highlight] {
        select(candidates(analysis, duration: duration, options: options), count: options.count)
    }

    // MARK: Candidates

    /// Candidates start and end on the draft's own sentence boundaries.
    static func sentences(_ words: [TranscriptWord]) -> [Speech.Sentence] { Speech.sentences(words) }

    public static func candidates(_ analysis: AssetAnalysis, duration: Double, options: HighlightOptions) -> [Highlight] {
        let context = Context(analysis: analysis, duration: duration)
        var out: [Highlight] = []
        let words = analysis.transcript?.words ?? []
        if words.count >= 10 {
            let sents = sentences(words)
            for i in sents.indices {
                var j = i
                while j < sents.count, sents[j].end - sents[i].start <= options.maxDuration {
                    let d = sents[j].end - sents[i].start
                    if d >= options.minDuration {
                        // Keep a little air around the speech (trimmed by the template's silence cut later).
                        let a = max(0, sents[i].start - min(0.3, sents[i].pauseBefore / 2))
                        let b = min(duration, sents[j].end + min(0.4, sents[j].pauseAfter / 2))
                        out.append(score(a, b, sentences: Array(sents[i...j]), context: context, options: options))
                    }
                    j += 1
                }
            }
        } else {
            // No speech (gameplay without commentary, B-roll): sliding windows anchored on scene cuts and every 5 s.
            var starts = Set(stride(from: 0.0, to: max(0, duration - options.minDuration), by: 5).map { $0 })
            for c in analysis.visual?.sceneCuts ?? [] where c < duration - options.minDuration { starts.insert(c) }
            for s in starts.sorted() {
                for len in [options.minDuration, options.targetDuration, options.maxDuration] where s + len <= duration {
                    out.append(score(s, s + len, sentences: [], context: context, options: options))
                }
            }
        }
        return out
    }

    // MARK: Scoring

    /// Precomputed recording-wide statistics.
    struct Context {
        var analysis: AssetAnalysis
        var duration: Double
        /// Loudness per second (dB of mean energy). 10 ms frames swing between syllables; seconds capture
        /// "this part is louder" (shouting, excitement) rather than vowels.
        var seconds: [Float]
        var medianRMS: Float
        var loudRMS: Float

        init(analysis: AssetAnalysis, duration: Double) {
            self.analysis = analysis
            self.duration = duration
            seconds = []
            if let rms = analysis.speech?.rms, rms.hop > 0 {
                let per = max(1, Int((1 / rms.hop).rounded()))
                var i = 0
                while i < rms.values.count {
                    let chunk = rms.values[i..<min(i + per, rms.values.count)]
                    let energy = chunk.reduce(Float(0)) { $0 + pow(10, $1 / 10) } / Float(chunk.count)
                    seconds.append(10 * log10(max(energy, 1e-12)))
                    i += per
                }
            }
            let voiced = seconds.filter { $0 > -60 }.sorted()   // ignore silent seconds
            medianRMS = voiced.isEmpty ? -40 : voiced[voiced.count / 2]
            loudRMS = voiced.isEmpty ? -20 : voiced[min(voiced.count - 1, Int(Double(voiced.count) * 0.95))]
        }
    }

    static let hookWords: Set<String> = ["why", "how", "what", "never", "always", "secret", "best", "worst", "mistake", "wait",
                                         "stop", "nobody", "everyone", "actually", "insane", "crazy", "biggest", "first", "only",
                                         "truth", "wrong", "here's", "this"]

    static func score(_ a: Double, _ b: Double, sentences: [Speech.Sentence], context: Context, options: HighlightOptions) -> Highlight {
        let d = b - a
        var signals: [String: Double] = [:]
        var reasons: [(Double, String)] = []
        let words = sentences.flatMap(\.words)
        let spoken = words.filter { !$0.isFiller }

        // Pacing: words per second, best around 2.2–3.6.
        if !sentences.isEmpty {
            let wps = Double(spoken.count) / max(d, 1)
            let pace = wps < 2.2 ? max(0, (wps - 0.8) / 1.4) : wps > 3.6 ? max(0, 1 - (wps - 3.6) / 2) : 1
            signals["pace"] = pace
            if pace > 0.9 { reasons.append((pace * 0.5, String(format: "tight pacing (%.1f words/s)", wps))) }
            let fillerRatio = Double(words.count - spoken.count) / Double(max(words.count, 1))
            signals["fillers"] = fillerRatio
            // Dead air inside the window.
            var dead = 0.0
            for (x, y) in zip(words, words.dropFirst()) where y.start - x.end > 1.5 { dead += y.start - x.end }
            signals["deadAir"] = dead / d
        }

        // Hook: clean start after a pause, question/number/hook words in the first sentence.
        if let first = sentences.first {
            var hook = first.pauseBefore >= 0.6 ? 0.4 : 0
            let text = first.words.map { $0.text.lowercased().trimmingCharacters(in: .punctuationCharacters) }
            if first.words.last?.text.hasSuffix("?") == true { hook += 0.35; reasons.append((0.35, "opens with a question")) }
            if first.words.contains(where: { $0.text.contains { $0.isNumber } }) { hook += 0.2; reasons.append((0.2, "opens with a number")) }
            if let w = text.prefix(8).first(where: { hookWords.contains($0) }) { hook += 0.25; reasons.append((0.25, "hook word “\(w)”")) }
            signals["hook"] = min(1, hook)
            // Completeness: ends on punctuation followed by a pause.
            let last = sentences.last!
            let complete = (last.words.last?.text.last.map { ".?!".contains($0) } ?? false ? 0.6 : 0) + (last.pauseAfter >= 0.4 ? 0.4 : 0)
            signals["complete"] = complete
        }

        // Energy: loudness above the recording's median and loud peaks.
        if !context.seconds.isEmpty {
            let i0 = max(0, Int(a)), i1 = min(context.seconds.count, Int(b.rounded(.up)))
            if i1 > i0 {
                let slice = context.seconds[i0..<i1].filter { $0 > -60 }
                let mean = slice.isEmpty ? -60 : slice.reduce(0, +) / Float(slice.count)
                let energy = Double(max(0, min(1, (mean - context.medianRMS + 6) / 12)))
                // Loud moments only count when they really stand out (≥ 6 dB over the typical second).
                let threshold = max(context.loudRMS, context.medianRMS + 6)
                let peaks = Double(slice.filter { $0 >= threshold }.count)
                signals["energy"] = energy
                signals["peaks"] = min(1, peaks / 3)
                if peaks >= 2 { reasons.append((0.3, "loud moments")) }
            }
        }

        // Payoff: laughter / applause / cheering, weighted towards the end of the window.
        var payoff = 0.0
        var payoffLabel: String?
        for e in context.analysis.events?.events ?? [] where e.end > a && e.start < b {
            let overlap = min(e.end, b) - max(e.start, a)
            let lateness = (max(e.start, a) - a) / d   // 0 at start … 1 at end
            let v = overlap * e.confidence * (0.6 + 0.6 * lateness)
            if v > payoff { payoffLabel = e.label }
            payoff += v
        }
        signals["payoff"] = min(1, payoff / 2)
        if let label = payoffLabel, payoff > 0.4 { reasons.append((payoff, "\(label.replacingOccurrences(of: "_", with: " ")) at \(Self.clock(a + d / 2))")) }

        // Visual action (mostly for gameplay): average change and cut density.
        if let vis = context.analysis.visual {
            let inside = vis.samples.filter { $0.time >= a && $0.time < b }
            if !inside.isEmpty {
                let change = inside.map(\.change).reduce(0, +) / Double(inside.count)
                let cuts = Double(vis.sceneCuts.filter { $0 >= a && $0 < b }.count)
                signals["action"] = min(1, change * 4 + cuts / 10)
                if change > 0.15 { reasons.append((change, "lots of on-screen action")) }
            }
        }

        // Length preference.
        let lengthFit = exp(-pow((d - options.targetDuration) / max(options.targetDuration * 0.5, 1), 2))
        signals["length"] = lengthFit

        let raw = 1.2 * (signals["hook"] ?? 0)
            + 0.9 * (signals["complete"] ?? 0)
            + 1.0 * (signals["pace"] ?? 0)
            + 0.8 * (signals["energy"] ?? 0)
            + 0.5 * (signals["peaks"] ?? 0)
            + 1.6 * (signals["payoff"] ?? 0)
            + (sentences.isEmpty ? 1.4 : 0.4) * (signals["action"] ?? 0)
            + 0.6 * lengthFit
            - 1.5 * (signals["fillers"] ?? 0)
            - 2.0 * (signals["deadAir"] ?? 0)
        let score = 1 / (1 + exp(-(raw - 2.6)))
        let reason = reasons.sorted { $0.0 > $1.0 }.prefix(3).map(\.1).joined(separator: ", ")
        let text = words.map(\.text).joined(separator: " ")
        return Highlight(start: a, end: b, score: score, reason: reason.isEmpty ? "steady segment" : reason, text: text, signals: signals)
    }

    // MARK: Selection

    /// Greedy best-first selection of non-overlapping candidates, returned in score order.
    public static func select(_ candidates: [Highlight], count: Int) -> [Highlight] {
        var picked: [Highlight] = []
        for c in candidates.sorted(by: { ($0.score, -$0.start) > ($1.score, -$1.start) }) {
            if picked.count >= count { break }
            if picked.contains(where: { $0.start < c.end && c.start < $0.end }) { continue }
            picked.append(c)
        }
        return picked
    }

    public static func clock(_ s: Double) -> String {
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}
