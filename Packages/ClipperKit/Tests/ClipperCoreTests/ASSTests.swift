import Foundation
import Testing
@testable import ClipperCore

/// Same look as the built-in "bold-pop" caption style (ClipperAutomation isn't a dependency of these tests).
let boldPop = TextStyle(font: "AvenirNext-Heavy", size: 0.052, color: .white, stroke: .black, strokeWidth: 0.09,
                        uppercase: true, maxWidth: 0.82, position: NormPoint(0.5, 0.68),
                        highlight: .init(color: RGBA(hex: "#FFD60A")), emphasisColor: RGBA(hex: "#4ADE80"),
                        animation: .pop, wordsPerPage: 3, maxLines: 2)
let cleanSubtitle = TextStyle(font: "HelveticaNeue-Medium", size: 0.034, color: .white, shadow: nil,
                              box: .init(color: RGBA(0, 0, 0, 0.6), padding: 0.35, cornerRadius: 0.2),
                              maxWidth: 0.86, position: NormPoint(0.5, 0.84), animation: .fade, wordsPerPage: 7, maxLines: 2)

func word(_ text: String, _ start: Double, _ end: Double, emphasis: Bool = false) -> CaptionContent.Word {
    .init(text: text, start: RationalTime(seconds: start), end: RationalTime(seconds: end), emphasis: emphasis)
}

func captionItem(_ start: Double, _ end: Double, _ words: [CaptionContent.Word], style: String) -> Item {
    Item(range: TimeRange(seconds: start, end), content: .caption(CaptionContent(words: words, style: style)))
}

/// Two pages in "bold-pop" (karaoke) and one in "clean-subtitle" (plain) on a 1080×1920 canvas.
func captionTimeline() -> Timeline {
    var tl = Timeline(name: "ASS test", canvas: .vertical1080, styles: ["bold-pop": boldPop, "clean-subtitle": cleanSubtitle])
    tl.tracks = [Track(kind: .caption, name: "Captions", items: [
        captionItem(1.5, 3.25, [word("Hello", 0.1, 0.5), word("brave", 0.6, 0.9), word("2026!", 1.0, 1.6, emphasis: true)], style: "bold-pop"),
        captionItem(3.25, 4.0, [word("{curly}", 0, 0.3), word("back\\slash", 0.35, 0.7)], style: "bold-pop"),
        captionItem(4.0, 6.0, [word("Plain", 0, 0.4), word("subtitle", 0.5, 1), word("KEY", 1.1, 1.5, emphasis: true)], style: "clean-subtitle"),
    ], language: "en")]
    return tl
}

func dialogueLines(_ ass: String) -> [String] { ass.split(separator: "\n").map(String.init).filter { $0.hasPrefix("Dialogue: ") } }

/// "H:MM:SS.cc" → centiseconds.
func centiseconds(_ stamp: Substring) -> Int {
    let p = stamp.split(separator: ":")
    let s = p[2].split(separator: ".")
    return Int(p[0])! * 360_000 + Int(p[1])! * 6000 + Int(s[0])! * 100 + Int(s[1])!
}

func karaokeTotal(_ text: Substring) -> Int {
    text.matches(of: /\\k(\d+)/).reduce(0) { $0 + Int($1.output.1)! }
}

@Suite struct ASSTests {
    @Test func colourIsAABBGGRRWithInvertedAlpha() {
        #expect(ASS.colour(.white) == "&H00FFFFFF")
        #expect(ASS.colour(RGBA(1, 0, 0)) == "&H000000FF")                 // red sits in the low byte
        #expect(ASS.colour(RGBA(hex: "#FFD60A")!) == "&H000AD6FF")
        #expect(ASS.colour(RGBA(0, 0, 0, 0.6)) == "&H66000000")             // 60 % opaque → alpha 0x66 (40 % transparent)
        #expect(ASS.colour(.clear) == "&HFF000000")                         // fully transparent
        #expect(ASS.inlineColour(RGBA(hex: "#4ADE80")!) == "&H80DE4A&")
    }

    @Test func timestamps() {
        #expect(ASS.timestamp(centiseconds: 0) == "0:00:00.00")
        #expect(ASS.timestamp(centiseconds: 366_110) == "1:01:01.10")
        #expect(ASS.centiseconds(RationalTime(seconds: 3.256)) == 326)
    }

    @Test func karaokeDurationsSumExactlyToThePage() {
        let words = [word("a", 0.12, 0.3), word("bb", 0.333, 0.5), word("ccc", 0.777, 0.9)]
        let d = ASS.karaokeDurations(words, length: 175)
        #expect(d == [33, 45, 97])                       // first word from the page start, last until the page end
        #expect(d.reduce(0, +) == 175)
        // Words starting past the page end are clamped; still sums exactly.
        let late = ASS.karaokeDurations([word("x", 0, 1), word("y", 5, 6)], length: 120)
        #expect(late == [120, 0])
        #expect(ASS.karaokeDurations([word("only", 0.5, 1)], length: 42) == [42])
        #expect(ASS.karaokeDurations([], length: 42).isEmpty)
    }

    @Test func dialogueKaraokeSumsMatchEventLengths() throws {
        let ass = Subtitles.ass(captionTimeline())
        let lines = dialogueLines(ass)
        #expect(lines.count == 3)
        for line in lines {
            let f = line.dropFirst("Dialogue: ".count).split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false)
            #expect(f.count == 10)
            let length = centiseconds(f[2]) - centiseconds(f[1])
            if f[3] == "bold-pop" { #expect(karaokeTotal(f[9]) == length) } else { #expect(!f[9].contains("\\k")) }
        }
        #expect(lines[0].hasPrefix("Dialogue: 0,0:00:01.50,0:00:03.25,bold-pop,,0,0,0,,"))
        // Uppercase style; the highlight moves (\k), each word reverts to its own colour when the next starts,
        // and the emphasised word is green before/after being spoken.
        #expect(lines[0].hasSuffix(",{\\k60\\t(600,601,\\1c&HFFFFFF&)}HELLO {\\k40\\1c&H0AD6FF&\\t(1000,1001,\\1c&HFFFFFF&)}BRAVE {\\k75\\1c&H0AD6FF&\\2c&H80DE4A&}2026!"))
        // Plain style: emphasis colour, no karaoke.
        #expect(lines[2].hasSuffix(",,Plain subtitle KEY"))   // clean-subtitle has no emphasis colour
    }

    @Test func emphasisInPlainStyle() {
        var tl = captionTimeline()
        tl.styles["clean-subtitle"]!.emphasisColor = RGBA(hex: "#4ADE80")
        let lines = dialogueLines(Subtitles.ass(tl))
        #expect(lines[2].hasSuffix(",,Plain subtitle {\\c&H80DE4A&}KEY{\\r}"))
    }

    @Test func escaping() {
        #expect(ASS.escape("a{b}c\nd\r\ne\\N") == "a\\{b\\}c\\Nd\\Ne\u{FF3C}N")
        let lines = dialogueLines(Subtitles.ass(captionTimeline()))
        #expect(lines[1].contains("}\\{CURLY\\} {"))
        #expect(lines[1].hasSuffix("}BACK\u{FF3C}SLASH"))
        // No stray override blocks: every unescaped "{" closes before the next opens.
        for line in lines {
            let text = line.split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false)[9]
            var depth = 0, previous: Character = " "
            for ch in text {
                if ch == "{" && previous != "\\" { depth += 1; #expect(depth == 1) }
                if ch == "}" && previous != "\\" { depth -= 1; #expect(depth == 0) }
                previous = ch
            }
            #expect(depth == 0)
        }
    }

    @Test func positionToAlignmentAndMargins() {
        func style(_ x: Double, _ y: Double, _ a: TextStyle.Alignment = .center) -> TextStyle {
            TextStyle(alignment: a, position: NormPoint(x, y))
        }
        #expect(ASS.alignment(style(0.5, 0.9)) == 2)
        #expect(ASS.alignment(style(0.5, 0.68)) == 2)
        #expect(ASS.alignment(style(0.5, 0.5)) == 5)
        #expect(ASS.alignment(style(0.5, 0.54)) == 5)
        #expect(ASS.alignment(style(0.5, 0.4)) == 8)
        #expect(ASS.alignment(style(0.5, 0.1, .left)) == 7)
        #expect(ASS.alignment(style(0.5, 0.9, .right)) == 3)
        #expect(ASS.alignment(style(0.5, 0.5, .left)) == 4)

        let canvas = Canvas.vertical1080
        // Bottom: (1 − 0.75) × 1920 − half the 0.045 × 1920 font size.
        #expect(ASS.marginV(style(0.5, 0.75), canvas: canvas) == 437)
        // Top: 0.15 × 1920 − 43.2.
        #expect(ASS.marginV(style(0.5, 0.15), canvas: canvas) == 245)
        #expect(ASS.marginV(style(0.5, 0.5), canvas: canvas) == 0)
        let lr = ASS.marginsLR(TextStyle(maxWidth: 0.8, position: NormPoint(0.6, 0.8)), canvas: canvas)
        #expect(lr.left == 216 && lr.right == 0)
    }

    @Test func styleLines() {
        let canvas = Canvas.vertical1080
        let pop = ASS.styleLine(name: "bold-pop", style: boldPop, canvas: canvas)
        #expect(pop == "Style: bold-pop,Avenir Next Heavy,99.84,&H000AD6FF,&H00FFFFFF,&H00000000,&H66000000,-1,0,0,0,100,100,0,0,1,8.99,3.99,2,97,97,564,1")
        // 23 fields as declared in the Format line.
        #expect(pop.dropFirst("Style: ".count).split(separator: ",", omittingEmptySubsequences: false).count == 23)

        // Background box → opaque box (BorderStyle 3) in the box colour, padding as the box border.
        let box = ASS.styleLine(name: "clean-subtitle", style: cleanSubtitle, canvas: canvas)
        #expect(box == "Style: clean-subtitle,Helvetica Neue Medium,65.28,&H00FFFFFF,&H00FFFFFF,&H66000000,&H66000000,0,0,0,0,100,100,0,0,3,22.85,0,2,76,76,275,1")

        // Highlight that only adds a box: the box colour becomes the spoken word's text colour.
        let karaokeBox = TextStyle(font: "AvenirNext-Bold", size: 0.046, color: .white, maxWidth: 0.84, position: NormPoint(0.5, 0.7),
                                   highlight: .init(color: .white, box: RGBA(hex: "#7C3AED")))
        #expect(ASS.styleLine(name: "k", style: karaokeBox, canvas: canvas).hasPrefix("Style: k,Avenir Next Bold,88.32,&H00ED3A7C,&H00FFFFFF,"))

        // Font name resolver is pluggable (the exporter uses Core Text's full name).
        #expect(ASS.styleLine(name: "x", style: boldPop, canvas: canvas, fontName: { _ in "Custom, Font" }).hasPrefix("Style: x,Custom  Font,"))
    }

    @Test func fontNames() {
        #expect(ASS.fullName(postScript: "AvenirNext-Heavy") == "Avenir Next Heavy")
        #expect(ASS.fullName(postScript: "Helvetica-Bold") == "Helvetica Bold")
        #expect(ASS.fullName(postScript: "HelveticaNeue-Medium") == "Helvetica Neue Medium")
        #expect(ASS.fullName(postScript: "SFProDisplay-Bold") == "SF Pro Display Bold")
        #expect(ASS.fullName(postScript: "Inter-Regular") == "Inter")
        #expect(ASS.fullName(postScript: "Menlo") == "Menlo")
        #expect(ASS.isBold(postScript: "AvenirNext-Heavy") && ASS.isBold(postScript: "Inter-SemiBold"))
        #expect(!ASS.isBold(postScript: "HelveticaNeue-Medium") && !ASS.isBold(postScript: "Bold"))
        #expect(ASS.isItalic(postScript: "Helvetica-BoldOblique") && !ASS.isItalic(postScript: "Helvetica-Bold"))
    }

    @Test func scriptStructure() {
        let ass = Subtitles.ass(captionTimeline())
        #expect(ass.hasPrefix("[Script Info]\n"))
        for line in ["ScriptType: v4.00+", "PlayResX: 1080", "PlayResY: 1920", "ScaledBorderAndShadow: yes", "WrapStyle: 0",
                     "[V4+ Styles]", "[Events]",
                     "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text"] {
            #expect(ass.contains("\n\(line)\n"), "missing \(line)")
        }
        // One style per used TextStyle, sorted by name; unused styles are left out.
        let styles = ass.split(separator: "\n").filter { $0.hasPrefix("Style: ") }.map { $0.split(separator: ",")[0] }
        #expect(styles == ["Style: bold-pop", "Style: clean-subtitle"])
        // Track selection: hidden tracks only when asked for explicitly; unknown styles fall back to "Default" defaults.
        var tl = captionTimeline()
        tl.tracks[0].hidden = true
        #expect(dialogueLines(Subtitles.ass(tl)).isEmpty)
        #expect(dialogueLines(Subtitles.ass(tl, track: tl.tracks[0].id)).count == 3)
        #expect(dialogueLines(Subtitles.ass(tl, language: "en")).count == 3)
        tl.styles = [:]
        #expect(Subtitles.ass(tl, track: tl.tracks[0].id).contains("\nStyle: bold-pop,Helvetica Bold,86.4,"))
    }

    @Test func unspacedLanguagesJoinWithoutSpaces() {
        var tl = captionTimeline()
        tl.tracks[0].items = [captionItem(0, 2, [word("今日は", 0, 0.5), word("いい天気。", 0.5, 1)], style: "clean-subtitle")]
        tl.tracks[0].language = "ja"
        #expect(dialogueLines(Subtitles.ass(tl))[0].hasSuffix(",,今日はいい天気。"))
        #expect(Subtitles.srt(tl).contains("\n今日はいい天気。\n"))
    }

    /// ffmpeg's ASS demuxer + decoder must accept the script and re-encode every event (skipped without ffmpeg).
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg"), "ffmpeg not installed at /opt/homebrew/bin/ffmpeg"))
    func ffmpegParsesTheScript() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clipper-ass-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var tl = captionTimeline()
        tl.styles["clean-subtitle"]!.emphasisColor = RGBA(hex: "#4ADE80")
        let file = dir.appendingPathComponent("captions.ass")
        try Subtitles.ass(tl).write(to: file, atomically: true, encoding: .utf8)

        func ffmpeg(_ args: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
            p.arguments = ["-hide_banner", "-nostdin", "-v", "error", "-i", file.path] + args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            try p.run()
            let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
        }
        // A bare `-f null -` has no default subtitle codec in ffmpeg 8 ("Output file does not contain any stream"),
        // so map the stream and force a decode → ASS re-encode of every event.
        let parse = try ffmpeg(["-map", "0", "-c:s", "ass", "-f", "null", "-"])
        #expect(parse.status == 0 && parse.stderr.isEmpty, "ffmpeg -f null: \(parse.stderr)")
        let remux = try ffmpeg(["-map", "0", "-c:s", "ass", "-f", "ass", "-"])
        #expect(remux.status == 0, "ffmpeg → ass: \(remux.stderr)")
        #expect(dialogueLines(remux.stdout).count == 3)
        #expect(remux.stdout.contains("PlayResY: 1920"))
        // Decode → SRT runs ffmpeg's override-tag parser over every event (it turns colours into <font> tags).
        let srt = try ffmpeg(["-map", "0", "-c:s", "subrip", "-f", "srt", "-"])
        #expect(srt.status == 0, "ffmpeg → srt: \(srt.stderr)")
        let plain = srt.stdout.replacing(/<[^>]*>/, with: "")
        #expect(plain.contains("HELLO BRAVE 2026!"))
        #expect(plain.contains("Plain subtitle KEY"))
        #expect(plain.components(separatedBy: " --> ").count - 1 == 3)
    }
}

@Suite struct SidecarTests {
    @Test func visibleAndPerLanguageSidecars() {
        var tl = captionTimeline()
        var es = tl.tracks[0]
        es.id = UUID(); es.name = "Captions (es)"; es.hidden = true; es.language = "es"
        es.items = [captionItem(1.5, 3.25, [word("Hola", 0, 0.8), word("valiente", 0.8, 1.6)], style: "bold-pop")]
        tl.tracks.append(es)
        tl.tracks.append(Track(kind: .caption, name: "Empty", language: "fr"))   // no cues → no file

        let files = Subtitles.sidecars(tl, formats: [.srt, .vtt, .ass])
        #expect(files.map(\.suffix) == ["srt", "en.srt", "es.srt", "vtt", "en.vtt", "es.vtt", "ass", "en.ass", "es.ass"])
        let esSRT = files.first { $0.suffix == "es.srt" }!.contents
        #expect(esSRT == "1\n00:00:01,500 --> 00:00:03,250\nHola valiente\n")
        // The plain sidecar is what is burned in: the visible track only.
        #expect(!files.first { $0.suffix == "srt" }!.contents.contains("Hola"))
        #expect(files.first { $0.suffix == "es.ass" }!.contents.contains("{\\k80\\t(800,801,\\1c&HFFFFFF&)}HOLA {\\k95\\1c"))

        // Nothing visible: only the language files.
        tl.tracks[0].hidden = true
        #expect(Subtitles.sidecars(tl, formats: [.srt]).map(\.suffix) == ["en.srt", "es.srt"])
        #expect(Subtitles.languages(tl) == ["en", "es", "fr"])
        #expect(Subtitles.fileTag("zh-Hant") == "zh-Hant" && Subtitles.fileTag("x/../y") == "x____y")
    }

    @Test func masterPresetsIncludeASS() {
        #expect(ExportPreset.named("master-hevc")!.sidecars == [.srt, .vtt, .ass])
        #expect(ExportPreset.named("master-prores422hq")!.sidecars == [.srt, .vtt, .ass])
        #expect(ExportPreset.named("shorts-1080x1920")!.sidecars == [.srt])
    }

    @Test func trackLanguageIsOptionalAndOldDocumentsRoundTripByteForByte() throws {
        let tl = captionTimeline()
        var old = tl
        old.tracks[0].language = nil
        let oldData = try ClipperJSON.encode(old)
        #expect(!String(decoding: oldData, as: UTF8.self).contains("\"language\""))   // nil is never written
        let decoded = try ClipperJSON.decode(Timeline.self, from: oldData)
        #expect(decoded.tracks[0].language == nil)
        #expect(try ClipperJSON.encode(decoded) == oldData)

        let data = try ClipperJSON.encode(tl)
        #expect(String(decoding: data, as: UTF8.self).contains("\"language\" : \"en\""))
        let back = try ClipperJSON.decode(Timeline.self, from: data)
        #expect(back == tl && back.tracks[0].language == "en")
        #expect(try ClipperJSON.encode(back) == data)
    }

    @Test func languageScripts() {
        #expect(!CaptionLanguage.usesWordSpaces("zh-Hant") && !CaptionLanguage.usesWordSpaces("ja") && !CaptionLanguage.usesWordSpaces("th"))
        #expect(CaptionLanguage.usesWordSpaces("es") && CaptionLanguage.usesWordSpaces(nil) && CaptionLanguage.usesWordSpaces("ko"))
        #expect(CaptionLanguage.isRightToLeft("ar") && CaptionLanguage.isRightToLeft("he-IL") && !CaptionLanguage.isRightToLeft("en"))
        #expect(CaptionLanguage.startsRightToLeft("«שלום» world") && CaptionLanguage.startsRightToLeft("123 مرحبا"))
        #expect(!CaptionLanguage.startsRightToLeft("hello שלום") && !CaptionLanguage.startsRightToLeft("123"))
    }
}

@Suite struct SidecarDedupTests {
    func captionTrack(_ lang: String, hidden: Bool, text: String) -> Track {
        Track(kind: .caption, items: [Item(range: TimeRange(seconds: 0, 1),
              content: .caption(CaptionContent(words: [.init(text: text, start: .zero, end: RationalTime(seconds: 1))], style: "s")))],
              hidden: hidden, language: lang)
    }

    @Test func singleLanguageWritesOnePlainFile() {
        let tl = Timeline(name: "t", canvas: .vertical1080, tracks: [captionTrack("en", hidden: false, text: "hi")])
        #expect(Subtitles.sidecars(tl, formats: [.srt]).map(\.suffix) == ["srt"])
    }

    @Test func translationsGetTheirOwnFiles() {
        let tl = Timeline(name: "t", canvas: .vertical1080, tracks: [captionTrack("en", hidden: false, text: "hi"),
                                                                      captionTrack("es", hidden: true, text: "hola")])
        #expect(Subtitles.sidecars(tl, formats: [.srt]).map(\.suffix) == ["srt", "en.srt", "es.srt"])
    }
}
