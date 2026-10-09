import AVFoundation
import ClipperCore
import ClipperEngine
import Foundation

/// Optional transcription through a locally installed whisper.cpp (`whisper-cli`, e.g. `brew install whisper-cpp`).
///
/// S3: whisper keeps fillers and gets near-perfect text but has loose word timing and runs ~9× realtime (turbo), so it
/// is an opt-in alternative to `AppleTranscriber`. The audio (of any audio or video file) is decoded to a temporary
/// 16 kHz mono WAV, then `whisper-cli -oj -ml 1 -sow` produces one JSON segment per word.
public struct WhisperTranscriber: Transcriber {
    public var modelPath: URL
    public var executable: URL

    /// `executable` defaults to the first `whisper-cli` found on PATH, /opt/homebrew/bin or /usr/local/bin.
    public init(modelPath: URL, executable: URL? = nil) {
        self.modelPath = modelPath
        self.executable = executable ?? Self.findExecutable() ?? URL(fileURLWithPath: "/opt/homebrew/bin/whisper-cli")
    }

    public var id: String { "whisper-" + modelPath.deletingPathExtension().lastPathComponent }

    public static func isAvailable(modelPath: URL) -> Bool {
        findExecutable() != nil && FileManager.default.isReadableFile(atPath: modelPath.path)
    }

    static func findExecutable() -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        let fm = FileManager.default
        return (path + ["/opt/homebrew/bin", "/usr/local/bin"])
            .map { URL(fileURLWithPath: $0).appendingPathComponent("whisper-cli") }
            .first { fm.isExecutableFile(atPath: $0.path) }
    }

    public func transcribe(url: URL, locale: Locale, range: ClosedRange<Double>? = nil) async throws -> Transcript {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw TranscriptionError.unavailable("whisper-cli not found")
        }
        guard FileManager.default.isReadableFile(atPath: modelPath.path) else {
            throw TranscriptionError.unavailable("whisper model not found at \(modelPath.path)")
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("clipper-whisper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let wav = work.appendingPathComponent("audio.wav")
        try await offCooperativePool {
            try Self.writeWAV(try await AudioReader.readMono(url: url, sampleRate: 16_000, range: range), to: wav)
        }
        try Task.checkCancellation()

        let language = locale.language.languageCode?.identifier ?? "en"
        let base = work.appendingPathComponent("out")
        let status = try await Self.run(executable, arguments: [
            "-m", modelPath.path, "-f", wav.path, "-oj", "-ml", "1", "-sow", "-l", language, "-np", "-of", base.path,
        ])
        try Task.checkCancellation()
        guard status == 0 else { throw TranscriptionError.failed("whisper-cli exited with status \(status)") }

        let json = try Data(contentsOf: base.appendingPathExtension("json"))
        let offset = max(0, range?.lowerBound ?? 0)
        let words = try Self.parse(json).map { w -> TranscriptWord in
            var w = w
            w.start += offset
            w.end += offset
            return w
        }
        return Transcript(locale: locale.identifier(.bcp47), engine: id, words: Fillers.markFillers(words))
    }

    /// Parses whisper.cpp `-oj` output: `transcription[].text` with `offsets.from/to` in milliseconds.
    /// Empty segments and bracketed annotations (`[BLANK_AUDIO]`, `[Music]`) are skipped.
    static func parse(_ data: Data) throws -> [TranscriptWord] {
        struct Output: Decodable {
            struct Segment: Decodable {
                struct Offsets: Decodable { var from: Double; var to: Double }
                var offsets: Offsets
                var text: String
            }
            var transcription: [Segment]
        }
        let out = try JSONDecoder().decode(Output.self, from: data)
        return out.transcription.flatMap { seg -> [TranscriptWord] in
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.hasPrefix("["), !text.hasPrefix("(") else { return [] }
            return WordSplitter.split(text, start: seg.offsets.from / 1000, end: seg.offsets.to / 1000, confidence: nil)
        }
    }

    static func writeWAV(_ samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 65_536
        var i = 0
        while i < samples.count {
            let n = min(chunk, samples.count - i)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(n)) else {
                throw TranscriptionError.failed("could not allocate audio buffer")
            }
            buffer.frameLength = AVAudioFrameCount(n)
            samples.withUnsafeBufferPointer { src in
                buffer.floatChannelData![0].update(from: src.baseAddress! + i, count: n)
            }
            try file.write(from: buffer)
            i += n
        }
    }

    /// Runs a process to completion; cancelling the calling task terminates it.
    static func run(_ executable: URL, arguments: [String]) async throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let box = UncheckedSendable(process)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
                box.value.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
                do { try box.value.run() } catch {
                    box.value.terminationHandler = nil
                    cont.resume(throwing: TranscriptionError.failed("could not launch whisper-cli: \(error.localizedDescription)"))
                }
            }
        } onCancel: {
            if box.value.isRunning { box.value.terminate() }
        }
    }
}
