import AVFoundation
import ClipperCore
import Foundation
import Testing
@testable import ClipperEngine

@Suite struct SoundEffectsTests {
    static let lengths: [SoundEffect: Double] = [.whoosh: 0.35, .pop: 0.07, .click: 0.012, .ding: 0.6, .bleep: 0.25]

    func read(_ url: URL) throws -> (rate: Double, channels: Int, bits: Int, samples: [Float]) {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let bits = (file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int) ?? 0
        return (file.fileFormat.sampleRate, Int(file.fileFormat.channelCount), bits, samples)
    }

    @Test func effectsAreWrittenOnceAt48kMono16Bit() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sfx-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let assets = try SoundEffects.ensure(in: dir)
        #expect(Set(assets.keys) == Set(SoundEffect.allCases))
        var dates: [SoundEffect: Date] = [:]
        for effect in SoundEffect.allCases {
            let asset = try #require(assets[effect])
            #expect(asset.url == dir.appending(path: "\(effect.rawValue).wav"))
            #expect(asset.tags == ["sfx"] && asset.info.kind == .audio && asset.info.audioSampleRate == 48_000)
            let (rate, channels, bits, samples) = try read(asset.url)
            #expect(rate == 48_000 && channels == 1 && bits == 16)
            #expect(abs(Double(samples.count) / 48_000 - Self.lengths[effect]!) < 0.001, "\(effect) length")
            #expect(asset.info.duration == RationalTime(value: Int64(samples.count), scale: 48_000))
            let peak = 20 * log10(Double(samples.map { abs($0) }.max()!))
            let rms = 10 * log10(samples.reduce(0) { $0 + Double($1 * $1) } / Double(samples.count))
            #expect(abs(peak + 6) < 0.1, "\(effect) peak \(peak) dBFS")
            #expect(rms > -26 && rms < -8, "\(effect) RMS \(rms) dBFS")
            #expect(abs(samples.last!) < 0.01, "\(effect) ends silent")
            dates[effect] = try FileManager.default.attributesOfItem(atPath: asset.url.path)[.modificationDate] as? Date
        }

        // Rewrites nothing, returns the same assets.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)],
                                              ofItemAtPath: assets[.pop]!.url.path)
        let again = try SoundEffects.ensure(in: dir)
        #expect(again == assets)
        let popDate = try FileManager.default.attributesOfItem(atPath: assets[.pop]!.url.path)[.modificationDate] as? Date
        #expect(popDate == Date(timeIntervalSince1970: 1_000_000))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["bleep.wav", "click.wav", "ding.wav", "pop.wav", "whoosh.wav"])

        // Deterministic: a deleted file comes back byte for byte.
        let original = try Data(contentsOf: assets[.whoosh]!.url)
        try FileManager.default.removeItem(at: assets[.whoosh]!.url)
        _ = try SoundEffects.ensure(in: dir)
        #expect(try Data(contentsOf: assets[.whoosh]!.url) == original)
    }
}
