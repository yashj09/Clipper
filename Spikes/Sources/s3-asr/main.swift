// S3 (part 1): Apple SpeechAnalyzer + SpeechTranscriber word-level transcription.
// Writes Spikes/out/s3/apple_<fixture>.json in a common format: {engine, seconds, words:[{w,start,end}]}.
// scripts/eval_asr.py scores this file and the whisper.cpp output against Fixtures/speech_truth.json.
import AVFoundation
import Speech
import SpikeKit

struct Word: Codable { let w: String; let start: Double; let end: Double }
struct Span: Codable { let start: Double; let end: Double; let speech: Bool }
struct Transcript: Codable { let engine: String; let fixture: String; let seconds: Double; let audioSeconds: Double; let words: [Word]; let vad: [Span] }

func transcribe(_ url: URL) async throws -> (words: [Word], vad: [Span], seconds: Double, audioSeconds: Double) {
    let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) ?? Locale(identifier: "en-US")
    let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                        attributeOptions: [.audioTimeRange, .transcriptionConfidence])
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        print("  downloading on-device speech model for \(locale.identifier)…")
        try await request.downloadAndInstall()
    }
    let file = try AVAudioFile(forReading: url)
    let audioSeconds = Double(file.length) / file.processingFormat.sampleRate
    let detector = SpeechDetector(detectionOptions: .init(sensitivityLevel: .high), reportResults: true)
    let analyzer = SpeechAnalyzer(modules: [transcriber, detector])
    let vadTask = Task {
        var spans: [Span] = []
        for try await r in detector.results {
            spans.append(Span(start: r.range.start.seconds, end: r.range.end.seconds, speech: r.speechDetected))
        }
        return spans
    }

    let start = ContinuousClock.now
    let collector = Task {
        var words: [Word] = []
        for try await result in transcriber.results {
            for run in result.text.runs {
                guard let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] else { continue }
                let text = String(result.text[run.range].characters).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                // A run can hold more than one token; split evenly if so (rare).
                let parts = text.split(separator: " ")
                let step = range.duration.seconds / Double(parts.count)
                for (i, p) in parts.enumerated() {
                    words.append(Word(w: String(p), start: range.start.seconds + Double(i) * step,
                                      end: range.start.seconds + Double(i + 1) * step))
                }
            }
        }
        return words
    }
    if let last = try await analyzer.analyzeSequence(from: file) {
        try await analyzer.finalizeAndFinish(through: last)
    } else {
        await analyzer.cancelAndFinishNow()
    }
    let words = try await collector.value
    let vad = try await vadTask.value
    return (words, vad, (ContinuousClock.now - start).seconds, audioSeconds)
}

print("S3 — Apple SpeechTranscriber")
print("  SpeechTranscriber.isAvailable = \(SpeechTranscriber.isAvailable)")
for fixture in ["speech_clean.wav", "speech_noisy.wav"] {
    let (words, vad, secs, audio) = try await transcribe(Spike.fixture(fixture))
    let speechSpans = vad.filter(\.speech)
    print("  VAD: \(vad.count) results, \(speechSpans.count) speech spans; first: " +
          speechSpans.prefix(4).map { String(format: "%.2f–%.2f", $0.start, $0.end) }.joined(separator: ", "))
    print(String(format: "  %@: %d words in %.2fs (%.0f× realtime)", fixture, words.count, secs, audio / secs))
    print("   “" + words.prefix(24).map(\.w).joined(separator: " ") + " …”")
    let t = Transcript(engine: "apple", fixture: fixture, seconds: secs, audioSeconds: audio, words: words, vad: vad)
    let url = Spike.out("s3").appendingPathComponent("apple_\(fixture.replacingOccurrences(of: ".wav", with: "")).json")
    try JSONEncoder().encode(t).write(to: url)
}
