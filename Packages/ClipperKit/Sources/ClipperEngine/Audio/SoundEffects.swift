import AVFoundation
import ClipperCore
import Foundation

/// Synthesised sound effects: no downloads, no licences. Deterministic, so every library gets the same files.
public enum SoundEffects {
    public static let sampleRate = 48_000.0
    /// Bumped when an effect's sound or length changes. Files and asset keys carry it, so a library made with an
    /// earlier version keeps its old assets (old drafts still play) and gets the new ones alongside.
    public static let version = 2

    /// Writes `<directory>/<name>-v<version>.wav` (48 kHz mono 16-bit) for each effect that has no file yet, and
    /// returns an asset per effect with an ID derived from its name and version, so drafts reference the same asset
    /// in every run.
    public static func ensure(in directory: URL) throws -> [SoundEffect: MediaAsset] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var out: [SoundEffect: MediaAsset] = [:]
        for effect in SoundEffect.allCases {
            let url = directory.appending(path: "\(effect.rawValue)-v\(version).wav", directoryHint: .notDirectory)
            let samples = render(effect)
            if !FileManager.default.fileExists(atPath: url.path) { try write(samples, to: url) }
            out[effect] = asset(effect, url: url, frames: samples.count)
        }
        return out
    }

    static func asset(_ effect: SoundEffect, url: URL, frames: Int) -> MediaAsset {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in "sfx|\(effect.rawValue)|v\(version)".utf8 { hash ^= UInt64(b); hash = hash &* 0x100_0000_01b3 }
        var g = IDGenerator(seed: hash)
        return MediaAsset(id: g.uuid(), key: AssetKey("sfx-\(effect.rawValue)-v\(version)"), name: effect.rawValue.capitalized, url: url,
                          info: MediaInfo(kind: .audio, duration: RationalTime(value: Int64(frames), scale: Int32(sampleRate)),
                                          audioChannels: 1, audioSampleRate: sampleRate),
                          tags: ["sfx"])
    }

    /// Written to a temporary file and moved into place, so an interrupted write never leaves a truncated effect.
    /// Another process writing the same file first wins: the content is identical.
    static func write(_ samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let temp = url.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).wav", directoryHint: .notDirectory)
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            let file = try AVAudioFile(forWriting: temp, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count))!
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            try file.write(from: buffer)
        }
        do {
            try FileManager.default.moveItem(at: temp, to: url)
        } catch {
            guard FileManager.default.fileExists(atPath: url.path) else { throw error }
        }
    }

    /// The effect's samples, peak-normalised to −6 dBFS.
    static func render(_ effect: SoundEffect) -> [Float] {
        let sr = sampleRate
        var noise = IDGenerator(seed: 0x5F3_E1F7)
        func white() -> Double { 2 * noise.unit() - 1 }
        var x: [Double]
        switch effect {
        case .whoosh:
            // White noise through a band-pass whose centre sweeps 400 → 2500 Hz, under a raised-cosine envelope.
            let n = Int(0.35 * sr)
            x = []
            x.reserveCapacity(n)
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in 0..<n {
                let p = Double(i) / Double(n - 1)
                let f = 400 * pow(2500 / 400, p), q = 1.2
                let w = 2 * Double.pi * f / sr, alpha = sin(w) / (2 * q)
                let a0 = 1 + alpha
                let b0 = alpha / a0, b2 = -alpha / a0, a1 = -2 * cos(w) / a0, a2 = (1 - alpha) / a0
                let input = white()
                let y = b0 * input + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1; x1 = input; y2 = y1; y1 = y
                x.append(y * 0.5 * (1 - cos(2 * Double.pi * p)))
            }
        case .pop:
            // A sine sweeping 900 → 300 Hz with an exponential decay, 1 ms attack.
            let n = Int(0.07 * sr)
            var phase = 0.0
            x = (0..<n).map { i in
                let t = Double(i) / sr, p = Double(i) / Double(n)
                phase += 2 * Double.pi * 900 * pow(300.0 / 900, p) / sr
                return sin(phase) * exp(-t / 0.018) * min(1, t / 0.001) * min(1, Double(n - i) / (0.003 * sr))
            }
        case .click:
            // A noise burst: 2 ms linear attack, then a fast decay.
            let n = Int(0.012 * sr)
            x = (0..<n).map { i in
                let t = Double(i) / sr
                let env = t < 0.002 ? t / 0.002 : exp(-(t - 0.002) / 0.003)
                return white() * env * min(1, Double(n - i) / (0.001 * sr))
            }
        case .ding:
            // 1320 Hz with a quiet second harmonic, exponential decay; 2 ms attack, 20 ms release so the end is silent.
            let n = Int(0.6 * sr)
            x = (0..<n).map { i in
                let t = Double(i) / sr
                let tone = sin(2 * Double.pi * 1320 * t) + 0.2 * sin(2 * Double.pi * 2640 * t)
                return tone * exp(-t / 0.15) * min(1, t / 0.002) * min(1, Double(n - i) / (0.02 * sr))
            }
        case .bleep:
            // 1 kHz with 10 ms ramps, long enough to cover any silenced stretch; the draft cuts it to the stretch.
            let n = Int(2.0 * sr), ramp = 0.01 * sr
            x = (0..<n).map { i in sin(2 * Double.pi * 1000 * Double(i) / sr) * min(1, Double(i) / ramp, Double(n - i) / ramp) }
        }
        let peak = x.reduce(0) { max($0, abs($1)) }
        let gain = peak > 0 ? pow(10, -6.0 / 20) / peak : 0
        return x.map { Float($0 * gain) }
    }
}
