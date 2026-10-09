import AVFoundation
import ClipperCore
import CoreMedia
import Foundation

/// Measures the audio of any AVFoundation-readable media file (EBU R128 integrated loudness, true peak,
/// loudness range).
///
/// The audio is decoded to interleaved Float32 PCM at its native sample rate. Files with several audio
/// tracks are measured as their mix (what playback would produce). For more than two channels the reader
/// is asked for a fixed channel order (see `LoudnessMeter.defaultWeights`) so that LFE is excluded and
/// surrounds get the 1.41 weight; if the decoder can't produce that layout the native order is used.
public enum AudioFileLoudness {
    public enum MeasureError: Error, Sendable, CustomStringConvertible {
        case noAudioTrack(URL)
        case readFailed(String)

        public var description: String {
            switch self {
            case .noAudioTrack(let url): "No audio track in \(url.lastPathComponent)"
            case .readFailed(let message): "Audio decode failed: \(message)"
            }
        }
    }

    public static func measure(url: URL) async throws -> LoudnessInfo {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw MeasureError.noAudioTrack(url) }

        var channels = 0
        var sampleRate = 0.0
        for track in tracks {
            for description in try await track.load(.formatDescriptions) {
                guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { continue }
                channels = max(channels, Int(asbd.mChannelsPerFrame))
                sampleRate = max(sampleRate, asbd.mSampleRate)
            }
        }
        if channels <= 0 { channels = 2 }
        if sampleRate <= 0 { sampleRate = 48_000 }

        if channels > 2, let layout = layoutTag(channels: channels) {
            do {
                return try read(asset: asset, tracks: tracks, channels: channels, sampleRate: sampleRate, layout: layout)
            } catch {
                // Fall through: decode in the source's native channel order.
            }
        }
        return try read(asset: asset, tracks: tracks, channels: channels, sampleRate: sampleRate, layout: nil)
    }

    /// Channel orders matching `LoudnessMeter.defaultWeights`.
    static func layoutTag(channels: Int) -> AudioChannelLayoutTag? {
        switch channels {
        case 3: kAudioChannelLayoutTag_MPEG_3_0_A      // L R C
        case 4: kAudioChannelLayoutTag_Quadraphonic    // L R Ls Rs
        case 5: kAudioChannelLayoutTag_MPEG_5_0_A      // L R C Ls Rs
        case 6: kAudioChannelLayoutTag_MPEG_5_1_A      // L R C LFE Ls Rs
        case 7: kAudioChannelLayoutTag_MPEG_6_1_A      // L R C LFE Ls Rs Cs
        case 8: kAudioChannelLayoutTag_MPEG_7_1_C      // L R C LFE Ls Rs Rls Rrs
        default: nil
        }
    }

    private static func read(asset: AVAsset, tracks: [AVAssetTrack], channels: Int, sampleRate: Double,
                             layout: AudioChannelLayoutTag?) throws -> LoudnessInfo {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw MeasureError.readFailed(error.localizedDescription) }

        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ]
        if let layout {
            var acl = AudioChannelLayout()
            acl.mChannelLayoutTag = layout
            settings[AVChannelLayoutKey] = Data(bytes: &acl, count: MemoryLayout<AudioChannelLayout>.size)
        }

        let output: AVAssetReaderOutput
        if tracks.count == 1 {
            output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: settings)
        } else {
            output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        }
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MeasureError.readFailed("reader rejected the PCM output settings") }
        reader.add(output)
        guard reader.startReading() else {
            throw MeasureError.readFailed(reader.error?.localizedDescription ?? "could not start reading")
        }

        var meter: LoudnessMeter?
        var copyBuffer: [Float] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            if meter == nil {
                var outChannels = channels
                var outRate = sampleRate
                if let format = CMSampleBufferGetFormatDescription(sampleBuffer),
                   let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                    outChannels = max(1, Int(asbd.mChannelsPerFrame))
                    outRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : sampleRate
                }
                meter = LoudnessMeter(sampleRate: outRate, channels: outChannels)
            }
            let byteCount = CMBlockBufferGetDataLength(block)
            let sampleCount = byteCount / MemoryLayout<Float>.size
            guard sampleCount > 0 else { continue }

            var lengthAtOffset = 0
            var totalLength = 0
            var pointer: UnsafeMutablePointer<CChar>?
            let status = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
                                                     totalLengthOut: &totalLength, dataPointerOut: &pointer)
            if status == kCMBlockBufferNoErr, let pointer, lengthAtOffset == totalLength {
                // Contiguous: measure straight from the decoder's buffer.
                pointer.withMemoryRebound(to: Float.self, capacity: sampleCount) {
                    meter!.process(interleaved: UnsafeBufferPointer(start: $0, count: sampleCount))
                }
            } else {
                if copyBuffer.count < sampleCount { copyBuffer = [Float](repeating: 0, count: sampleCount) }
                let copyStatus = copyBuffer.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: sampleCount * 4, destination: $0.baseAddress!)
                }
                guard copyStatus == kCMBlockBufferNoErr else { throw MeasureError.readFailed("CMBlockBuffer copy failed (\(copyStatus))") }
                copyBuffer.withUnsafeBufferPointer {
                    meter!.process(interleaved: UnsafeBufferPointer(rebasing: $0[0..<sampleCount]))
                }
            }
        }
        if reader.status == .failed {
            throw MeasureError.readFailed(reader.error?.localizedDescription ?? "unknown error")
        }
        return (meter ?? LoudnessMeter(sampleRate: sampleRate, channels: channels)).result()
    }
}
