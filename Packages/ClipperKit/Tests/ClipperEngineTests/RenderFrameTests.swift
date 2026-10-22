import ClipperCore
import CoreGraphics
import Foundation
import Testing
@testable import ClipperEngine

@Suite struct RenderFrameTests {
    /// RGBA bytes of `image`, drawn upright.
    static func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    /// Mean |a − b| over the RGB of rows `rows` (fractions of the height, from the top), 0…1.
    static func difference(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int, rows: ClosedRange<Double>) -> Double {
        var sum = 0.0, n = 0.0
        for y in Int(rows.lowerBound * Double(height))..<Int(rows.upperBound * Double(height)) {
            for x in 0..<width {
                for c in 0..<3 { let i = (y * width + x) * 4 + c; sum += abs(Double(a[i]) - Double(b[i])) }
                n += 3
            }
        }
        return sum / n / 255
    }

    @Test(.enabled(if: Fixture.url("bg_1080x1920_60.mov") != nil && Fixture.url("overlay_1280x720_30.mov") != nil, "Fixtures not present"))
    func frameHasTheTimelinesSizeAndItsCaption() async throws {
        let a = try #require(Fixture.url("bg_1080x1920_60.mov")), b = try #require(Fixture.url("overlay_1280x720_30.mov"))
        let bg = try await MediaProbe.makeAsset(a), overlay = try await MediaProbe.makeAsset(b)
        let words = ["covers", "carry", "words"].enumerated().map {
            CaptionContent.Word(text: $0.element, start: RationalTime(seconds: Double($0.offset) * 0.3), end: RationalTime(seconds: Double($0.offset + 1) * 0.3))
        }
        var caption = Item(range: TimeRange(seconds: 2, 4), content: .caption(CaptionContent(words: words, style: "caption")))
        caption.transform.position = .constant(NormPoint(0.5, 0.75))
        let video = Track(kind: .video, items: [
            Item(range: TimeRange(seconds: 0, 2), content: .media(MediaRef(asset: bg.id, source: TimeRange(seconds: 0, 2)))),
            Item(range: TimeRange(seconds: 2, 4), content: .media(MediaRef(asset: overlay.id, source: TimeRange(seconds: 0, 2)))),
        ])
        let plain = Timeline(name: "cover", canvas: .vertical1080, tracks: [video],
                             styles: ["caption": TextStyle(size: 0.06, uppercase: true)])
        var captioned = plain
        captioned.tracks.append(Track(kind: .caption, items: [caption]))
        let assets = [bg.id: bg, overlay.id: overlay]

        let frame = try await Exporter.renderFrame(captioned, assets: assets, at: RationalTime(seconds: 3), maxWidth: 540)
        #expect(frame.width == 540 && frame.height == 960)
        let with = Self.pixels(frame)
        #expect(with.reduce(0) { $0 + Int($1) } / with.count > 20, "not black")
        let without = Self.pixels(try await Exporter.renderFrame(plain, assets: assets, at: RationalTime(seconds: 3), maxWidth: 540))
        // Captions differ around their position and nowhere else; the second clip is the one showing.
        #expect(Self.difference(with, without, width: 540, height: 960, rows: 0.68...0.82) > 0.02)
        #expect(Self.difference(with, without, width: 540, height: 960, rows: 0.05...0.5) < 0.005)
        let first = Self.pixels(try await Exporter.renderFrame(plain, assets: assets, at: RationalTime(seconds: 1), maxWidth: 540))
        #expect(Self.difference(first, without, width: 540, height: 960, rows: 0.05...0.5) > 0.02)

        let out = Fixture.out("cover.jpg")
        try StillRenderer.writeJPEG(frame, to: out)
        let probed = try await MediaProbe.makeAsset(out)
        #expect(probed.info.kind == .image && probed.info.displayWidth == 540)
    }
}
