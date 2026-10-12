@testable import ClipperAnalysis
import ClipperCore
import Foundation
import Testing
import Translation

private func w(_ text: String, _ start: Double, _ end: Double, emphasis: Bool = false) -> CaptionContent.Word {
    .init(text: text, start: RationalTime(seconds: start), end: RationalTime(seconds: end), emphasis: emphasis)
}

/// Video track, an English caption track with two pages, and a title track.
private func timeline() -> Timeline {
    let video = Track(kind: .video)
    let captions = Track(kind: .caption, name: "Captions", items: [
        Item(name: "Caption 1", range: TimeRange(seconds: 1, 3), content: .caption(CaptionContent(words: [
            w("Hello", 0.2, 0.6), w("everyone", 0.7, 1.4), w("2026", 1.5, 1.8, emphasis: true)], style: "bold-pop")),
             origin: .auto(pass: "captions")),
        Item(name: "Caption 2", range: TimeRange(seconds: 3, 5), content: .caption(CaptionContent(words: [
            w("Thanks", 0, 0.5), w("for", 0.5, 0.7), w("watching!", 0.7, 1.5)], style: "bold-pop")),
             origin: .auto(pass: "captions")),
    ], language: "en")
    return Timeline(name: "t", canvas: .vertical1080, tracks: [video, captions, Track(kind: .title)],
                    styles: ["bold-pop": TextStyle(uppercase: true, highlight: .init(color: RGBA(1, 0.8, 0)))])
}

@Suite struct CaptionRetimingTests {
    @Test func spreadsProportionallyToWordLength() {
        let t = CaptionTranslator.retime(weights: [1, 3, 6], start: .zero, end: RationalTime(seconds: 1))
        #expect(t.map { $0.start.seconds } == [0, 0.1, 0.4])
        #expect(t.map { $0.end.seconds } == [0.1, 0.4, 1.0])
        #expect(CaptionTranslator.retime(weights: [], start: .zero, end: RationalTime(seconds: 1)).isEmpty)
        // Zero-length weights still get a share; a degenerate span collapses without going backwards.
        let z = CaptionTranslator.retime(weights: [0, 0], start: RationalTime(seconds: 2), end: RationalTime(seconds: 2))
        #expect(z.allSatisfy { $0.start == RationalTime(seconds: 2) && $0.end == RationalTime(seconds: 2) })
    }

    @Test func monotonicContiguousAndWithinThePage() {
        var g = IDGenerator(seed: 42)
        for _ in 0..<200 {
            let n = 1 + Int(g.unit() * 12)
            let weights = (0..<n).map { _ in Int(g.unit() * 15) }
            let start = RationalTime(seconds: g.unit() * 3), end = start + RationalTime(seconds: g.unit() * 4)
            let t = CaptionTranslator.retime(weights: weights, start: start, end: end)
            #expect(t.count == n)
            #expect(t.first!.start == start && t.last!.end == end.rescaled(to: RationalTime.defaultScale))
            for (i, s) in t.enumerated() {
                #expect(s.start <= s.end)
                #expect(s.start >= start && s.end <= end)
                if i > 0 { #expect(s.start == t[i - 1].end) }
            }
            // Shares follow weights: a heavier word never gets less time than a lighter one (± rounding ticks).
            let ticks = t.map { $0.end.value - $0.start.value }
            for i in 0..<n { for j in 0..<n where max(weights[i], 1) > max(weights[j], 1) { #expect(ticks[i] + 2 >= ticks[j]) } }
        }
    }

    @Test func spanIsWhereTheSourceWordsAreSpoken() {
        let page = CaptionContent(words: [w("a", 0.2, 0.6), w("b", 0.7, 1.4)], style: "s")
        let s = CaptionTranslator.wordSpan(page, duration: RationalTime(seconds: 2))
        #expect(s.start.seconds == 0.2 && s.end.seconds == 1.4)
        // Words past the item end are clamped; a degenerate span falls back to the whole item.
        let late = CaptionContent(words: [w("a", 2.5, 3)], style: "s")
        let d = CaptionTranslator.wordSpan(late, duration: RationalTime(seconds: 2))
        #expect(d.start == .zero && d.end.seconds == 2)
    }

    @Test func splittingWords() {
        #expect(CaptionTranslator.split("¡Hola  a todos,", language: "es", uppercase: false) == ["¡Hola", "a", "todos,"])
        #expect(CaptionTranslator.split("¡Hola a todos,", language: "es", uppercase: true) == ["¡Hola", "a", "todos"])
        // Unspaced scripts: short phrases broken after punctuation, never leaving punctuation on its own.
        let zh = CaptionTranslator.split("大家好，欢迎回到我的频道今天我们来测试一下！", language: "zh-Hans", uppercase: false)
        #expect(zh.first == "大家好，")
        #expect(zh.count == 4)                                              // 17 characters after "，" → 3 phrases
        #expect(zh.joined() == "大家好，欢迎回到我的频道今天我们来测试一下！")
        #expect(zh.allSatisfy { $0.count <= CaptionTranslator.unspacedChunk + 2 })
        // Cuts land on word boundaries: "我们" (we) and "频道" (channel) are never split.
        #expect(!zh.contains { $0.hasSuffix("我") } && !zh.contains { $0.hasSuffix("频") })
        print("TranslationTests: zh phrases \(zh)")
        #expect(CaptionTranslator.split("こんにちは 世界。", language: "ja", uppercase: true) == ["こんにちは", "世界"])
        #expect(CaptionTranslator.chunks("！！", max: 8) == ["！！"])
    }
}

@Suite struct CaptionTrackTests {
    private func translations(_ tl: Timeline, _ texts: [String]) -> [ItemID: String] {
        Dictionary(uniqueKeysWithValues: zip(tl.tracks[1].items.map(\.id), texts))
    }

    @Test func insertsHiddenTaggedTrackAfterTheSource() throws {
        let tl = timeline()
        let out = try CaptionTranslator.applying(translations(tl, ["Hola a todos 2026", "¡Gracias por ver!"]), to: tl,
                                                 sourceTrack: tl.tracks[1].id, language: "es")
        #expect(out.tracks.map(\.kind) == [.video, .caption, .caption, .title])
        let es = out.tracks[2]
        #expect(es.name == "Captions (es)" && es.hidden && es.language == "es" && !es.locked)
        #expect(out.tracks[1] == tl.tracks[1])                           // source untouched
        #expect(es.items.map(\.range) == tl.tracks[1].items.map(\.range))  // page timing unchanged
        #expect(es.items.allSatisfy { $0.origin == .auto(pass: "translation") })
        guard case .caption(let first) = es.items[0].content else { Issue.record("not a caption"); return }
        #expect(first.words.map(\.text) == ["Hola", "a", "todos", "2026"])
        #expect(first.style == "bold-pop")
        #expect(first.words.map(\.emphasis) == [false, false, false, true])
        // Spread over where the English words were spoken (0.2 … 1.8 s), by length 4:1:5:4.
        #expect(first.words.first!.start.seconds == 0.2 && first.words.last!.end.seconds == 1.8)
        #expect(abs(first.words[1].start.seconds - (0.2 + 1.6 * 4 / 14)) < 1e-4)
        // Uppercase styles drop trailing , . ; : (like the source captions) but keep ! and ?.
        guard case .caption(let second) = es.items[1].content else { return }
        #expect(second.words.map(\.text) == ["¡Gracias", "por", "ver!"])
    }

    @Test func idsAreDeterministicAndRerunsReplace() throws {
        let tl = timeline()
        let src = tl.tracks[1].id
        let a = try CaptionTranslator.applying(translations(tl, ["Hola", "Gracias"]), to: tl, sourceTrack: src, language: "es")
        let b = try CaptionTranslator.applying(translations(tl, ["Hola", "Gracias"]), to: tl, sourceTrack: src, language: "es")
        #expect(a == b)
        #expect(a.tracks[2].items[0].id == CaptionTranslator.derivedID(tl.tracks[1].items[0].id, "es"))
        #expect(a.tracks[2].items[0].id != tl.tracks[1].items[0].id)
        #expect(CaptionTranslator.derivedID(src, "es") != CaptionTranslator.derivedID(src, "fr"))
        #expect(a.tracks[2].id.uuidString.dropFirst(14).first == "8")    // RFC 9562 version 8

        // Running again on the result replaces the Spanish track (new text), keeping a user's choice to show it.
        var shown = a
        shown.tracks[2].hidden = false
        let again = try CaptionTranslator.applying(translations(tl, ["Buenas", "Adiós"]), to: shown, sourceTrack: src, language: "es")
        #expect(again.tracks.count == 4)
        #expect(again.tracks.filter { $0.language == "es" }.count == 1)
        #expect(again.tracks[2].id == a.tracks[2].id && !again.tracks[2].hidden)
        guard case .caption(let c) = again.tracks[2].items[0].content else { return }
        #expect(c.words.map(\.text) == ["Buenas"])

        // Another language adds its own track right after the source.
        let fr = try CaptionTranslator.applying(translations(tl, ["Bonjour", "Merci"]), to: again, sourceTrack: src, language: "fr")
        #expect(fr.tracks.compactMap(\.language) == ["en", "fr", "es"])
        #expect(fr.tracks[2].hidden)

        // A Spanish caption track the user made by hand is not a translation and is left alone.
        var manual = a
        manual.tracks.append(Track(kind: .caption, name: "Mis subtítulos", items: [
            Item(range: TimeRange(seconds: 0, 1), content: .caption(CaptionContent(words: [w("Hola", 0, 1)], style: "bold-pop")))],
                                   language: "es"))
        let kept = try CaptionTranslator.applying(translations(tl, ["Hola", "Gracias"]), to: manual, sourceTrack: src, language: "es")
        #expect(kept.tracks.filter { $0.language == "es" }.map(\.name) == ["Captions (es)", "Mis subtítulos"])
    }

    @Test func missingTranslationsAreSkippedAndSourcesResolved() throws {
        let tl = timeline()
        let out = try CaptionTranslator.applying([tl.tracks[1].items[1].id: "Gracias"], to: tl, sourceTrack: tl.tracks[1].id, language: "es")
        #expect(out.tracks[2].items.count == 1 && out.tracks[2].items[0].range == tl.tracks[1].items[1].range)
        #expect(try CaptionTranslator.sourceTrack(in: tl, nil).id == tl.tracks[1].id)
        #expect(throws: CaptionTranslationError.notACaptionTrack(tl.tracks[0].id)) { try CaptionTranslator.sourceTrack(in: tl, tl.tracks[0].id) }
        #expect(throws: CaptionTranslationError.noCaptionTrack) {
            try CaptionTranslator.sourceTrack(in: Timeline(name: "e", canvas: .vertical1080), nil)
        }
        #expect(CaptionTranslator.pages(of: tl.tracks[1], language: "en").map(\.text) == ["Hello everyone 2026", "Thanks for watching!"])
    }

    @Test func translatedTrackExportsAsLanguageSidecar() throws {
        let tl = timeline()
        let out = try CaptionTranslator.applying(translations(tl, ["Hola a todos", "Gracias"]), to: tl, sourceTrack: tl.tracks[1].id, language: "es")
        let files = Subtitles.sidecars(out, formats: [.srt])
        #expect(files.map(\.suffix) == ["srt", "en.srt", "es.srt"])
        #expect(files[2].contents.contains("00:00:01,000 --> 00:00:03,000\nHola a todos\n"))
        #expect(!files[0].contents.contains("Hola"))   // hidden: not in the burned-in sidecar
    }

    @Test func errorsExplainHowToInstall() {
        let message = CaptionTranslationError.pairNotInstalled(source: "en", target: "es").errorDescription!
        #expect(message.contains("System Settings ▸ General ▸ Language & Region ▸ Translation Languages"))
    }
}

/// Candidate targets for the live test, in order of preference. Only already-installed pairs are used; nothing is downloaded.
private let liveTargets = ["es", "fr", "de", "it", "pt-BR", "ja", "zh-Hans", "ko"].map { Locale.Language(identifier: $0) }

private func installedTarget() async -> Locale.Language? {
    let english = Locale.Language(identifier: "en")
    let status = await CaptionTranslator.availability(from: english, to: liveTargets)
    let target = liveTargets.first { status[$0] == .installed }
    if target == nil {
        let summary = liveTargets.map { "\($0.minimalIdentifier)=\(status[$0].map { "\($0)" } ?? "?")" }.joined(separator: " ")
        print("TranslationTests: skipping the live translation test — no installed en→X pair (\(summary)). "
              + "Install one in System Settings ▸ General ▸ Language & Region ▸ Translation Languages.")
    }
    return target
}

@Suite struct LiveTranslationTests {
    @Test(.enabled("no on-device translation pair from English is installed") { await installedTarget() != nil },
          .timeLimit(.minutes(1)))
    func translatesCaptionsOnDevice() async throws {
        let target = try #require(await installedTarget())
        let tag = target.minimalIdentifier
        let tl = timeline()
        let out = try await CaptionTranslator().addTranslatedTrack(to: tl, target: target)
        let track = try #require(out.tracks.first { $0.language == tag })
        #expect(track.hidden && out.tracks[2].id == track.id && track.items.count == 2)
        for (src, item) in zip(tl.tracks[1].items, track.items) {
            guard case .caption(let c) = item.content, case .caption(let s) = src.content else { Issue.record("not a caption"); continue }
            #expect(item.range == src.range)
            #expect(!c.words.isEmpty)
            #expect(c.words.allSatisfy { $0.start <= $0.end && $0.start >= .zero && $0.end <= item.range.duration })
            #expect(zip(c.words.dropFirst(), c.words).allSatisfy { $0.start == $1.end })
            print("TranslationTests: en→\(tag): \"\(s.text)\" → \"\(CaptionLanguage.join(c.words.map(\.text), language: tag))\"")
        }
        #expect(track.items.map { item -> String in
            guard case .caption(let c) = item.content else { return "" }
            return c.text
        } != tl.tracks[1].items.map { item -> String in
            guard case .caption(let c) = item.content else { return "" }
            return c.text
        })
        // Same language again: replaced, not duplicated, with identical IDs.
        let again = try await CaptionTranslator().addTranslatedTrack(to: out, target: target)
        #expect(again.tracks.count == out.tracks.count)
        #expect(again.tracks.first { $0.language == tag }!.items.map(\.id) == track.items.map(\.id))
    }

    @Test func sameLanguageIsRejected() async {
        await #expect(throws: CaptionTranslationError.sameLanguage("en")) {
            try await CaptionTranslator().addTranslatedTrack(to: timeline(), target: Locale.Language(identifier: "en-US"))
        }
    }
}
