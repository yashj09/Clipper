import ClipperCore
import Foundation

/// Tempo/beat grid and average energy for a music track (feeds `MusicTrack.bpm/energy/beats` and the BeatSnap pass).
public enum MusicAnalyzer {
    /// Analysis sample rate (the BeatTracker's reference rate).
    public static let sampleRate = 22_050.0

    /// Decodes the file to mono at 22.05 kHz, then runs `BeatTracker` and `BeatTracker.energy`.
    /// - Returns: beats (`bpm == 0` and no beats for silence), energy 0…1 and the decoded duration in seconds.
    public static func analyze(url: URL) async throws -> (beats: BeatGrid, energy: Double, duration: Double) {
        let samples = try await offCooperativePool { try await AudioReader.readMono(url: url, sampleRate: sampleRate) }
        try Task.checkCancellation()
        let beats = BeatTracker().analyze(samples: samples, sampleRate: sampleRate)
        return (beats, BeatTracker.energy(samples: samples), Double(samples.count) / sampleRate)
    }
}
