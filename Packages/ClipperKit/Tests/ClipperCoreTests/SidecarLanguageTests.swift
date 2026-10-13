import Foundation
import Testing
@testable import ClipperCore

@Suite struct SidecarLanguageTests {
    func captionTrack(_ language: String?, hidden: Bool) -> Track {
        Track(kind: .caption, items: [Item(range: TimeRange(seconds: 0, 1),
                                           content: .caption(CaptionContent(words: [.init(text: "w", start: .zero, end: RationalTime(seconds: 1))], style: "c")))],
              hidden: hidden, language: language)
    }

    func distinct(_ tracks: [Track]) -> [String] {
        let tl = Timeline(name: "t", canvas: .vertical1080, tracks: tracks)
        // Every distinct sidecar is one the exporter actually writes.
        let written = Set(Subtitles.sidecars(tl, formats: [.srt]).map(\.suffix))
        let result = Subtitles.distinctSidecars(tl, format: .srt)
        #expect(result.allSatisfy { written.contains($0.suffix) })
        return result.map { "\($0.suffix)=\($0.language ?? "?")" }
    }

    @Test func eachLanguageOnceWithItsLabel() {
        #expect(distinct([captionTrack("es", hidden: false)]) == ["srt=es"])                     // single language: plain file only
        #expect(distinct([captionTrack("en", hidden: false), captionTrack("es", hidden: true)]) == ["en.srt=en", "es.srt=es"])
        #expect(distinct([captionTrack(nil, hidden: false), captionTrack("es", hidden: true)]) == ["srt=?", "es.srt=es"])
        #expect(distinct([captionTrack(nil, hidden: false)]) == ["srt=?"])
        #expect(distinct([captionTrack("ja", hidden: true)]) == ["ja.srt=ja"])                  // nothing visible
    }
}

@Suite struct ExportPresetSettingsTests {
    @Test func sidecarSettingAndAspect() throws {
        let shorts = try #require(ExportPreset.named("shorts-1080x1920"))
        var settings = ClipperSettings.Export()
        #expect(shorts.applying(settings).sidecars == [.srt])
        settings.writeSidecars = false
        #expect(shorts.applying(settings).sidecars.isEmpty)
        #expect(shorts.matchesAspect(of: .vertical1080))
        #expect(!shorts.matchesAspect(of: .landscape1080))
        #expect(try #require(ExportPreset.named("master-hevc")).matchesAspect(of: .landscape1080))   // canvas-sized
    }
}
