import AVFoundation
import ClipperCore
import CoreText
import Foundation
import Testing
@testable import ClipperEngine

@Suite struct CanvasFrameTests {
    @Test func sameShapeFillsTheFrame() {
        let preview = CanvasFrame.fitting(canvas: SIMD2(1080, 1920), in: SIMD2(540, 960))
        #expect(preview == CanvasFrame(origin: .zero, size: SIMD2(540, 960), scale: 0.5))
        #expect(!preview.isLetterboxed)
        // Even-rounded preview buffers are a hair off the canvas aspect: still filled, as before.
        #expect(!CanvasFrame.fitting(canvas: SIMD2(1080, 1920), in: SIMD2(356, 634)).isLetterboxed)
    }

    @Test func otherShapeIsLetterboxedAndScaledUniformly() {
        // Vertical timeline exported with youtube-1080p: pillarboxed, text scaled by 1080/1920 (not 1920/1080).
        let pillar = CanvasFrame.fitting(canvas: SIMD2(1080, 1920), in: SIMD2(1920, 1080))
        #expect(pillar.scale == 1080.0 / 1920.0)
        #expect(pillar.size == SIMD2(607.5, 1080))
        #expect(pillar.origin == SIMD2(656, 0))
        let letter = CanvasFrame.fitting(canvas: SIMD2(1080, 1080), in: SIMD2(1080, 1920))
        #expect(letter.scale == 1 && letter.origin == SIMD2(0, 420) && letter.isLetterboxed)
    }

    @Test func mismatchedPresetLetterboxesInsteadOfCropping() async throws {
        // A full-frame white solid on a square canvas, rendered into a landscape frame.
        let solid = Item(range: TimeRange(seconds: 0, 1), content: .solid(RGBA(1, 1, 1)))
        let tl = Timeline(name: "square", canvas: .square1080, tracks: [Track(kind: .video, items: [solid])])
        let built = try await CompositionBuilder.build(tl, assets: [:], options: BuildOptions(outputSize: CGSize(width: 1920, height: 1080)))
        let t = CMTime(value: 1, timescale: 2)
        let frame = try #require(try await Pixels.readComposited(built, at: [t])[t])
        #expect(CVPixelBufferGetWidth(frame) == 1920)
        #expect(Pixels.mean(frame, NormRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)).x > 0.95)   // canvas
        #expect(Pixels.mean(frame, NormRect(x: 0, y: 0, width: 0.2, height: 1)).x < 0.05)         // left bar
        #expect(Pixels.mean(frame, NormRect(x: 0.8, y: 0, width: 0.2, height: 1)).x < 0.05)       // right bar
    }
}

@Suite struct TextMaxLinesTests {
    @Test func longTextShrinksToFitMaxLines() {
        let words = "this caption is far too long to fit in two lines at the style size".split(separator: " ").map(String.init)
        let capped = TextStyle(size: 0.05, maxWidth: 0.6, maxLines: 2)
        let base = Double(CTFontGetSize(TextRenderer.font(capped, canvasHeight: 1920)))
        let layout = TextRenderer.layout(words: words, style: capped, canvasWidth: 1080, canvasHeight: 1920)
        #expect(layout.lines.count <= 2 || layout.fontSize == base * TextRenderer.minimumShrink)
        #expect(layout.fontSize < base)
        #expect(layout.words.map(\.text) == words)                      // nothing dropped
        #expect(layout.words.allSatisfy { $0.rect.width > 0 })
        // Text that already fits keeps the style's size.
        let short = TextRenderer.layout(words: ["two", "words"], style: capped, canvasWidth: 1080, canvasHeight: 1920)
        #expect(short.fontSize == base && short.lines.count == 1)
        // maxLines 0 = no cap.
        var uncapped = capped; uncapped.maxLines = 0
        #expect(TextRenderer.layout(words: words, style: uncapped, canvasWidth: 1080, canvasHeight: 1920).fontSize == base)
        // The renderer draws at the size layout chose.
        #expect(TextRenderer.render(words: words, style: capped, canvasWidth: 1080, canvasHeight: 1920)?.height == Int(layout.size.height))
    }
}

@Suite struct LimiterTailTests {
    func format() throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(mSampleRate: Exporter.audioSampleRate, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                               mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var desc: CMAudioFormatDescription?
        try #require(CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                                    magicCookie: nil, extensions: nil, formatDescriptionOut: &desc) == noErr)
        return try #require(desc)
    }

    @Test func normalizedAudioKeepsItsLastSamples() throws {
        let fmt = try format()
        let frames = 1024, buffers = 6, channels = Exporter.audioChannels
        // Quiet ramp: never limited, so the stage output is exactly the input delayed by the limiter's latency.
        let input = (0..<(frames * buffers * channels)).map { Float($0 % 977) / 977 * 0.1 }
        let box = StageBox(LoudnessStage(gainDB: 0, ceilingDBTP: -1))
        let latency = try #require(box.stage).latencyFrames
        var out: [(time: CMTime, samples: [Float])] = []
        for b in 0..<buffers {
            let chunk = Array(input[(b * frames * channels)..<((b + 1) * frames * channels)])
            let sb = try #require(AudioSampleBuffers.make(chunk, channels: channels, format: fmt,
                                                           at: CMTime(value: CMTimeValue(b * frames), timescale: 48_000)))
            let processed = try #require(box.apply(sb))
            out.append((CMSampleBufferGetPresentationTimeStamp(processed), AudioSampleBuffers.floats(processed)))
        }
        let tail = try #require(box.tail())
        #expect(CMSampleBufferGetNumSamples(tail) == latency)
        // Stamped right after the last output buffer: no gap, no overlap.
        #expect(CMSampleBufferGetPresentationTimeStamp(tail) == CMTime(value: CMTimeValue(frames * buffers - latency), timescale: 48_000))
        out.append((CMSampleBufferGetPresentationTimeStamp(tail), AudioSampleBuffers.floats(tail)))

        #expect(out.first?.time == CMTime(value: CMTimeValue(-latency), timescale: 48_000))
        let all = out.flatMap(\.samples)
        // Dropping the leading delay (negative time, trimmed by the writer) leaves exactly the input, end included.
        #expect(Array(all.dropFirst(latency * channels)) == input)
    }

    @Test func noStageMeansNoTail() throws {
        #expect(StageBox(nil).tail() == nil)
        #expect(StageBox(GainStage(dB: 3)).tail() == nil)   // stages without latency have nothing held back
    }
}

@Suite struct ExportOverwriteTests {
    func textTimeline(_ text: String) -> Timeline {
        var item = Item(range: TimeRange(seconds: 0, 1), content: .text(TextContent(text: text, style: "t")))
        item.transform.position = .constant(.center)
        return Timeline(name: "t", canvas: Canvas(width: 320, height: 568), tracks: [Track(kind: .title, items: [item])],
                        styles: ["t": TextStyle(size: 0.1, shadow: nil)])
    }

    @Test func failedExportKeepsThePreviousFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clipper-overwrite-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("short.mp4")
        let preset = try #require(ExportPreset.named("master-hevc"))
        _ = try await Exporter.export(textTimeline("first"), assets: [:], preset: preset, to: url)
        let good = try Data(contentsOf: url)

        // Re-export of a timeline that can't render (its clip's media is gone).
        var broken = textTimeline("second")
        broken.tracks.append(Track(kind: .video, items: [Item(range: TimeRange(seconds: 0, 1),
                                                               content: .media(MediaRef(asset: UUID(), source: TimeRange(seconds: 0, 1))))]))
        await #expect(throws: (any Error).self) {
            _ = try await Exporter.export(broken, assets: [:], preset: preset, to: url)
        }
        #expect(try Data(contentsOf: url) == good)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("partial") }
        #expect(leftovers.isEmpty)

        // A successful re-export replaces it in place.
        _ = try await Exporter.export(textTimeline("third"), assets: [:], preset: preset, to: url)
        #expect(try Data(contentsOf: url) != good)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("partial") }.isEmpty)
    }
}

@Suite struct ProcessRunnerTests {
    @Test(.timeLimit(.minutes(1))) func chattyStderrDoesNotDeadlock() async throws {
        // ~300 KB on stderr: far more than a pipe buffers. Read only at exit, this used to block the child forever.
        do {
            try await Transcoder.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "head -c 300000 /dev/zero | tr '\\0' x >&2; echo done >&2; exit 3"])
            Issue.record("expected a failure")
        } catch let error as Transcoder.TranscodeError {
            guard case .failed(let log) = error else { Issue.record("\(error)"); return }
            #expect(log.hasSuffix("done\n"))
            #expect(log.utf8.count <= Transcoder.LogTail.limit)
        }
    }

    @Test(.timeLimit(.minutes(1))) func cancellationTerminatesTheProcess() async throws {
        let task = Task { try await Transcoder.run(URL(fileURLWithPath: "/bin/sleep"), ["30"]) }
        try await Task.sleep(for: .milliseconds(300))
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - start < .seconds(5))
    }
}
