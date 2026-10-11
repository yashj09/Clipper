import ClipperCore
import Foundation
import Testing
@testable import ClipperAutomation

/// A 10-minute synthetic "stream": steady talk, one punchy segment with a hook and a laugh, one slow filler-heavy segment.
func syntheticVOD() -> (AssetAnalysis, hook: ClosedRange<Double>, dull: ClosedRange<Double>) {
    var words: [TranscriptWord] = []
    var t = 1.0
    func say(_ sentence: String, wps: Double = 2.8, pauseAfter: Double = 0.7) {
        let tokens = sentence.split(separator: " ")
        for w in tokens {
            let filler = ["um", "uh"].contains(w.lowercased().trimmingCharacters(in: .punctuationCharacters))
            words.append(TranscriptWord(text: String(w), start: t, end: t + 0.8 / wps, isFiller: filler))
            t += 1 / wps
        }
        t += pauseAfter
    }
    let filler = "So we kept going through the level and checked the corners for loot like usual."
    while t < 200 { say(filler) }
    let hookStart = t
    say("Why does nobody talk about this secret room?", pauseAfter: 0.9)
    for _ in 0..<6 { say("You walk in and the whole floor drops and suddenly there are ten enemies behind you.", wps: 3.2) }
    say("And that is how I lost everything!", pauseAfter: 1.5)
    let hookEnd = t
    while t < 380 { say(filler) }
    let dullStart = t
    for _ in 0..<8 { say("Um so uh I think um we uh maybe go left um or right.", wps: 1.1, pauseAfter: 2.2) }
    let dullEnd = t
    while t < 600 { say(filler) }

    // Loudness: quiet baseline, louder in the hook segment.
    let hop = 0.01
    let rms = (0..<Int(610 / hop)).map { i -> Float in
        let s = Double(i) * hop
        return (hookStart...hookEnd).contains(s) ? -14 : -24
    }
    let laugh = SoundEvent(label: "laughter", start: hookEnd - 3, end: hookEnd - 0.5, confidence: 0.9)
    let analysis = AssetAnalysis(transcript: Transcript(locale: "en-US", engine: "test", words: words),
                                 speech: SpeechActivity(spans: [], rms: Envelope(hop: hop, values: rms), noiseFloor: -60, threshold: -50),
                                 events: SoundEvents(events: [laugh]))
    return (analysis, hookStart...hookEnd, dullStart...dullEnd)
}

@Suite struct HighlightTests {
    @Test func hookSegmentRanksFirstAndDullLast() {
        let (analysis, hook, dull) = syntheticVOD()
        let picks = HighlightFinder.find(analysis, duration: 610, options: HighlightOptions(count: 8))
        #expect(!picks.isEmpty)
        let top = picks[0]
        #expect(top.start >= hook.lowerBound - 1 && top.end <= hook.upperBound + 1, "top pick \(top.start)–\(top.end) vs hook \(hook)")
        #expect(top.reason.contains("question") || top.reason.contains("laughter"), "\(top.reason)")
        #expect(top.signals["payoff"] ?? 0 > 0.3)
        // Nothing overlapping, all within length bounds, sorted by score.
        for (i, a) in picks.enumerated() {
            #expect(a.duration >= 19.9 && a.duration <= 61)
            for b in picks[(i + 1)...] { #expect(!(a.start < b.end && b.start < a.end)) }
        }
        #expect(zip(picks, picks.dropFirst()).allSatisfy { $0.score >= $1.score })
        // The dull, filler-heavy stretch is never the top pick and scores below the hook.
        let all = HighlightFinder.candidates(analysis, duration: 610, options: HighlightOptions())
        let dullBest = all.filter { $0.start >= dull.lowerBound && $0.end <= dull.upperBound }.map(\.score).max() ?? 0
        #expect(dullBest < top.score - 0.1)
    }

    @Test func noSpeechFallsBackToVisualWindows() {
        let samples = stride(from: 0.0, to: 300, by: 1).map { t in
            VisualSample(time: t, change: (120...150).contains(t) ? 0.4 : 0.02, salient: nil)
        }
        let analysis = AssetAnalysis(visual: VisualActivity(samples: samples, sceneCuts: [120, 128, 135, 142]))
        let picks = HighlightFinder.find(analysis, duration: 300, options: HighlightOptions(count: 3))
        #expect(picks.first.map { $0.start <= 135 && $0.end >= 135 } == true, "\(picks.map { ($0.start, $0.end) })")
        #expect(picks.first?.reason.contains("action") == true)
    }

    @Test func sentencesSplitOnPunctuationAndPauses() {
        let w = [TranscriptWord(text: "Hello", start: 0, end: 0.3), TranscriptWord(text: "there.", start: 0.35, end: 0.6),
                 TranscriptWord(text: "Next", start: 0.7, end: 0.9), TranscriptWord(text: "bit", start: 2.0, end: 2.2)]
        let s = HighlightFinder.sentences(w)
        #expect(s.count == 3)
        #expect(s[2].pauseBefore > 1)
    }

    @Test func highlightDraftsUseTheSourceRange() {
        let (analysis, hook, _) = syntheticVOD()
        let top = HighlightFinder.find(analysis, duration: 610, options: HighlightOptions(count: 1))[0]
        let vod = videoAsset("vod", seconds: 610)
        let r = DraftPipeline.run(DraftInput(template: BuiltIns.talkingHead,
                                             clips: [ClipInput(asset: vod, analysis: analysis, inPoint: top.start, outPoint: top.end)]))
        let items = r.timeline.tracks.first { $0.kind == .video }!.items
        #expect(!items.isEmpty)
        for i in items {
            let src = i.content.mediaRef!.source
            #expect(src.start.seconds >= top.start - 0.01 && src.end.seconds <= top.end + 0.01)
        }
        _ = hook
    }

    @Test func saliencyReframesGameplayWithoutFaces() {
        let game = videoAsset("game", seconds: 30)   // 16:9 → full-frame 9:16 crop when alone
        let samples = stride(from: 0.0, to: 30, by: 1).map { t in
            VisualSample(time: t, change: 0.1, salient: NormRect(x: 0.05 + t * 0.025, y: 0.4, width: 0.15, height: 0.2))
        }
        let tr = transcript(["moving to the right while we talk about the plan for this round"], pauses: [])
        let r = DraftPipeline.run(DraftInput(template: BuiltIns.gameplay,
                                             clips: [ClipInput(asset: game, analysis: AssetAnalysis(transcript: tr, visual: VisualActivity(samples: samples, sceneCuts: [])))]))
        let item = r.timeline.tracks.first { $0.kind == .video }!.items[0]
        #expect(item.transform.focus.isAnimated)
        #expect(item.transform.focus.value(at: item.range.duration).x > item.transform.focus.value(at: .zero).x)
    }
}
