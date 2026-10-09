import ClipperCore

/// Energy-based voice/sound activity detector over an RMS envelope (S3: floor + 3 dB works best on noisy audio).
/// This is not a speech classifier: any sound clearly above the noise floor counts as activity.
public struct SpeechActivityDetector: Sendable {
    /// threshold = max(noiseFloor + marginDB, -50)
    public var marginDB: Float = 3
    /// Drop voiced blips shorter than this (seconds), after merging.
    public var minSpeech: Double = 0.10
    /// Merge voiced spans separated by less than this (seconds).
    public var minSilence: Double = 0.15
    /// Upper bound for the threshold's lower clamp (dBFS).
    public var absoluteMinThreshold: Float = -50

    public init() {}

    /// Noise floor = 10th percentile of the envelope. Returns spans of voice/sound activity.
    /// Frames strictly above the threshold are voiced; gaps shorter than `minSilence` are merged first,
    /// then spans shorter than `minSpeech` are dropped.
    public func detect(_ rms: Envelope) -> SpeechActivity {
        let v = rms.values
        guard !v.isEmpty, rms.hop > 0 else {
            return SpeechActivity(spans: [], rms: rms, noiseFloor: Envelope.silenceDB,
                                  threshold: absoluteMinThreshold)
        }
        let floor = Self.percentile(v, 0.10)
        let threshold = max(floor + marginDB, absoluteMinThreshold)

        // Voiced runs as frame index ranges [start, end).
        var runs: [(Int, Int)] = []
        var i = 0
        while i < v.count {
            if v[i] > threshold {
                let s = i
                while i < v.count && v[i] > threshold { i += 1 }
                runs.append((s, i))
            } else {
                i += 1
            }
        }
        let eps = 1e-9
        var merged: [(Int, Int)] = []
        for r in runs {
            if let last = merged.last, Double(r.0 - last.1) * rms.hop < minSilence - eps {
                merged[merged.count - 1].1 = r.1
            } else {
                merged.append(r)
            }
        }
        let spans = merged
            .filter { Double($0.1 - $0.0) * rms.hop >= minSpeech - eps }
            .map { SpeechActivity.Span(start: Double($0.0) * rms.hop, end: Double($0.1) * rms.hop) }
        return SpeechActivity(spans: spans, rms: rms, noiseFloor: floor, threshold: threshold)
    }

    /// Nearest-rank percentile (`sorted[Int(q·n)]`, as in the S3 prototype).
    static func percentile(_ values: [Float], _ q: Double) -> Float {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, max(0, Int(Double(sorted.count) * q)))]
    }
}
