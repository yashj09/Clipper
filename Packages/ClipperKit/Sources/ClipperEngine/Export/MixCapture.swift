import AVFoundation
import CoreMedia

/// Where the export pumps pull sample buffers from: an `AVAssetReaderOutput`, or the captured mix of a normalised export.
protocol SampleBufferSource {
    func copyNextSampleBuffer() -> CMSampleBuffer?
}

extension AVAssetReaderOutput: SampleBufferSource {}

/// The timeline's mixed audio (48 kHz stereo interleaved Float32), captured while a normalised export measures it and
/// streamed back during the render, so the composition's audio is decoded and mixed once per export.
enum MixCapture {
    static var format: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Exporter.audioSampleRate,
                      channels: AVAudioChannelCount(Exporter.audioChannels), interleaved: true)!
    }

    /// Appends sample buffers by presentation time: frame `n` of the file is time `n / 48 kHz`. A buffer starting
    /// after the end so far is preceded by silence; one overlapping it loses its overlapping head.
    final class Writer {
        private let file: AVAudioFile
        private let channels = Exporter.audioChannels
        private(set) var frames: Int64 = 0

        init(url: URL) throws {
            try? FileManager.default.removeItem(at: url)
            file = try AVAudioFile(forWriting: url, settings: MixCapture.format.settings, commonFormat: .pcmFormatFloat32,
                                   interleaved: true)
        }

        func write(_ samples: [Float], at time: CMTime) throws {
            let start = time.isNumeric ? time.convertScale(CMTimeScale(Exporter.audioSampleRate), method: .roundHalfAwayFromZero).value
                                       : frames
            if start > frames { try append(zeroFrames: Int(start - frames)) }
            let skip = Int(max(0, frames - start)) * channels
            guard skip < samples.count else { return }
            try samples.withUnsafeBufferPointer { try append(UnsafeBufferPointer(rebasing: $0[skip...])) }
        }

        func close() { file.close() }

        private func append(zeroFrames: Int) throws {
            var left = zeroFrames
            let zeros = [Float](repeating: 0, count: min(left, 48_000) * channels)
            while left > 0 {
                let n = min(left, 48_000)
                try zeros.withUnsafeBufferPointer { try append(UnsafeBufferPointer(rebasing: $0[..<(n * channels)])) }
                left -= n
            }
        }

        private func append(_ samples: UnsafeBufferPointer<Float>) throws {
            let n = samples.count / channels
            guard n > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(n))
            else { return }
            buffer.frameLength = AVAudioFrameCount(n)
            buffer.mutableAudioBufferList.pointee.mBuffers.mData!.copyMemory(from: samples.baseAddress!,
                                                                            byteCount: n * channels * MemoryLayout<Float>.size)
            try file.write(from: buffer)
            frames += Int64(n)
        }
    }

    /// Streams a capture back as sample buffers stamped by frame position. `copyNextSampleBuffer` runs on the audio
    /// pump's queue while `cancel` may come from any thread; the lock covers both.
    final class Reader: SampleBufferSource, @unchecked Sendable {
        static let chunkFrames: AVAudioFrameCount = 16_384
        private let lock = NSLock()
        private let file: AVAudioFile
        private let description: CMAudioFormatDescription
        private let buffer: AVAudioPCMBuffer
        private var position: Int64 = 0
        private var cancelled = false
        private var failure: Error?

        init(url: URL) throws {
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
            guard file.processingFormat.sampleRate == Exporter.audioSampleRate,
                  Int(file.processingFormat.channelCount) == Exporter.audioChannels,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: Self.chunkFrames)
            else { throw CocoaError(.fileReadCorruptFile) }
            self.buffer = buffer
            description = file.processingFormat.formatDescription
        }

        /// A read error that ended the stream early.
        var error: Error? { lock.withLock { failure } }

        func cancel() { lock.withLock { cancelled = true } }

        func copyNextSampleBuffer() -> CMSampleBuffer? {
            lock.withLock {
                // Reading at the end throws eofErr rather than returning zero frames.
                guard !cancelled, failure == nil, file.framePosition < file.length else { return nil }
                do {
                    try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(Self.chunkFrames), file.length - file.framePosition)))
                } catch {
                    failure = error
                    return nil
                }
                let n = Int(buffer.frameLength)
                guard n > 0 else { return nil }
                let channels = Exporter.audioChannels
                let samples = [Float](UnsafeBufferPointer(start: buffer.mutableAudioBufferList.pointee.mBuffers.mData!
                    .assumingMemoryBound(to: Float.self), count: n * channels))
                let time = CMTime(value: position, timescale: CMTimeScale(Exporter.audioSampleRate))
                position += Int64(n)
                return AudioSampleBuffers.make(samples, channels: channels, format: description, at: time)
            }
        }
    }
}
