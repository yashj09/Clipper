import ClipperCore
import Foundation

/// Makes files AVFoundation can't read (webm/VP9, mkv, AV1, …) playable by transcoding once to a 10-bit HEVC
/// "mezzanine" with FFmpeg + VideoToolbox. The original stays the source of truth (its content key identifies
/// the asset); the mezzanine becomes `MediaAsset.playableURL`.
public enum Transcoder {
    public enum TranscodeError: Error, CustomStringConvertible {
        case ffmpegMissing
        case failed(String)
        public var description: String {
            switch self {
            case .ffmpegMissing: "FFmpeg is needed to import this format (brew install ffmpeg)"
            case .failed(let log): "FFmpeg failed: \(log.suffix(400))"
            }
        }
    }

    public static var ffmpegURL: URL? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Transcodes `source` into `directory` (named by content key so repeated imports reuse it). Uses the shared
    /// encode scheduler at background priority.
    public static func makePlayable(_ source: URL, key: AssetKey, into directory: URL) async throws -> URL {
        guard let ffmpeg = ffmpegURL else { throw TranscodeError.ffmpegMissing }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let out = directory.appendingPathComponent("\(key.rawValue).mov")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        let tmp = directory.appendingPathComponent("\(key.rawValue).partial.mov")
        try? FileManager.default.removeItem(at: tmp)
        let args = ["-hide_banner", "-loglevel", "error", "-y", "-i", source.path,
                    "-map", "0:v:0?", "-map", "0:a:0?",
                    "-c:v", "hevc_videotoolbox", "-profile:v", "main10", "-pix_fmt", "p010le", "-q:v", "70", "-tag:v", "hvc1",
                    "-c:a", "pcm_s16le", "-fps_mode", "passthrough", tmp.path]
        try await EncodeScheduler.shared.run(.background) {
            try await run(ffmpeg, args)
        }
        try FileManager.default.moveItem(at: tmp, to: out)
        return out
    }

    static func run(_ exe: URL, _ args: [String]) async throws {
        let process = Process()
        process.executableURL = exe
        process.arguments = args
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { p in
                let log = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if p.terminationStatus == 0 { cont.resume() } else { cont.resume(throwing: TranscodeError.failed(log)) }
            }
            do { try process.run() } catch { cont.resume(throwing: error) }
        }
    }

    /// Probes `url`; if AVFoundation can't read it, transcodes and probes the mezzanine instead.
    public static func makeAsset(_ url: URL, transcodeDirectory: URL) async throws -> MediaAsset {
        do {
            return try await MediaProbe.makeAsset(url)
        } catch MediaError.unreadable(let u) {
            throw MediaError.unreadable(u)
        } catch {
            // AVFoundation rejects some containers/codecs with assorted errors; try FFmpeg before giving up.
            // Key from the original file so re-imports dedupe; size/duration-free variant until we can probe.
            let provisionalKey = try MediaProbe.assetKey(url, duration: .zero)
            let playable = try await makePlayable(url, key: provisionalKey, into: transcodeDirectory)
            var asset = try await MediaProbe.makeAsset(playable)
            asset.key = provisionalKey
            asset.url = url
            asset.name = url.deletingPathExtension().lastPathComponent
            asset.playableURL = playable
            return asset
        }
    }
}
