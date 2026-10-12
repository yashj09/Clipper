import ClipperCore
import Foundation
import Testing
@testable import ClipperEngine

@Suite struct SidecarWritingTests {
    @Test func writesVisibleAndLanguageSidecarsNextToTheExport() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clipper-sidecars-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func page(_ start: Double, _ end: Double, _ words: [String]) -> Item {
            Item(range: TimeRange(seconds: start, end), content: .caption(CaptionContent(words: words.enumerated().map { i, w in
                .init(text: w, start: RationalTime(seconds: Double(i) * 0.4), end: RationalTime(seconds: Double(i + 1) * 0.4))
            }, style: "c")))
        }
        var tl = Timeline(name: "s", canvas: .vertical1080, styles: ["c": TextStyle(highlight: .init(color: RGBA(1, 1, 0)))])
        tl.tracks = [Track(kind: .caption, name: "Captions", items: [page(1, 2, ["Hello", "there"])], language: "en"),
                     Track(kind: .caption, name: "Captions (ja)", items: [page(1, 2, ["こんにちは", "皆さん"])], hidden: true, language: "ja")]

        let urls = try Exporter.writeSidecars(tl, formats: [.srt, .ass], besides: dir.appendingPathComponent("My Short.mp4"))
        #expect(urls.map(\.lastPathComponent) == ["My Short.srt", "My Short.en.srt", "My Short.ja.srt",
                                                  "My Short.ass", "My Short.en.ass", "My Short.ja.ass"])
        #expect(try String(contentsOf: dir.appendingPathComponent("My Short.ja.srt"), encoding: .utf8)
            == "1\n00:00:01,000 --> 00:00:02,000\nこんにちは皆さん\n")
        let ass = try String(contentsOf: dir.appendingPathComponent("My Short.ass"), encoding: .utf8)
        // Core Text resolves the PostScript name to the installed font's full name.
        #expect(ass.contains("\nStyle: c,Helvetica Bold,86.4,"))
        #expect(ass.contains("{\\k40\\t(400,401,\\1c&HFFFFFF&)}Hello {\\k60\\1c&H00FFFF&}there"))
    }
}

@Suite struct RightToLeftLayoutTests {
    @Test func rightToLeftWordsRunFromTheRight() {
        let style = TextStyle(size: 0.04, maxWidth: 0.9)
        let ltr = TextRenderer.layout(words: ["one", "two", "three"], style: style, canvasWidth: 1080, canvasHeight: 1920)
        #expect(ltr.words[0].rect.minX < ltr.words[1].rect.minX && ltr.words[1].rect.minX < ltr.words[2].rect.minX)

        let rtl = TextRenderer.layout(words: ["שלום", "לכולם", "היום"], style: style, canvasWidth: 1080, canvasHeight: 1920)
        #expect(rtl.words[0].rect.minX > rtl.words[1].rect.minX && rtl.words[1].rect.minX > rtl.words[2].rect.minX)
        // Same line box as left-to-right placement would use: first word flush right, last flush left.
        #expect(abs(rtl.words[0].rect.maxX - rtl.lines[0].maxX) < 0.001)
        #expect(abs(rtl.words[2].rect.minX - rtl.lines[0].minX) < 0.001)
        // Wrapped lines stay in logical order top to bottom.
        let narrow = TextStyle(size: 0.04, maxWidth: 0.2)
        let wrapped = TextRenderer.layout(words: ["مرحبا", "بكم", "جميعا", "اليوم"], style: narrow, canvasWidth: 1080, canvasHeight: 1920)
        #expect(wrapped.lines.count > 1)
        #expect(zip(wrapped.words, wrapped.words.dropFirst()).allSatisfy { $0.line < $1.line || $0.rect.minX > $1.rect.minX })
    }
}
