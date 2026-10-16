import ClipperCore
import Foundation

/// A spoken word placed on the timeline.
struct TimedWord {
    var text: String
    var start: Double
    var end: Double
    var isFiller: Bool
    /// Known emphasis (re-paging keeps the user's); nil = decide from the text.
    var emphasis: Bool? = nil
}

enum Captions {
    /// Groups words into caption pages: at most `style.wordsPerPage` words, breaking at sentence ends and pauses.
    static func items(words: [TimedWord], styleName: String, style: TextStyle, rate: FrameRate, ids: inout IDGenerator) -> [Item] {
        let spoken = words.filter { !$0.isFiller }.sorted { $0.start < $1.start }
        var pages: [[TimedWord]] = []
        var current: [TimedWord] = []
        let maxChars = style.wordsPerPage * 9
        for w in spoken {
            if let last = current.last {
                let pause = w.start - last.end
                let sentenceEnd = last.text.last.map { ".?!".contains($0) } ?? false
                let chars = current.reduce(0) { $0 + $1.text.count + 1 } + w.text.count
                if current.count >= style.wordsPerPage || sentenceEnd || pause > 0.6 || chars > maxChars {
                    pages.append(current); current = []
                }
            }
            current.append(w)
        }
        if !current.isEmpty { pages.append(current) }

        var items: [Item] = []
        for (i, page) in pages.enumerated() {
            var start = RationalTime.frames(page[0].start, rate).floorToFrame(rate)
            // Pages whose first words fall in the same frame (zero-length or tightly packed ASR words): start a frame
            // after the previous page so that one keeps at least a frame instead of shrinking to nothing and vanishing.
            if let prev = items.last, start <= prev.start { start = prev.start + rate.frameDuration }
            var endSeconds = max(page.last!.end + 0.15, start.seconds + 0.3)
            if i + 1 < pages.count { endSeconds = min(endSeconds, pages[i + 1][0].start) }
            var end = RationalTime.frames(endSeconds, rate)
            if end <= start { end = start + rate.frameDuration }
            if let prev = items.last, prev.end > start { items[items.count - 1].range = TimeRange(start: prev.start, end: start) }
            let longest = page.enumerated().max { $0.element.text.count < $1.element.text.count }?.offset
            let words = page.enumerated().map { j, w in
                CaptionContent.Word(text: display(w.text, style: style),
                                    start: RationalTime(seconds: max(0, w.start - start.seconds)),
                                    end: RationalTime(seconds: max(0, w.end - start.seconds)),
                                    emphasis: w.emphasis ?? (isEmphasis(w.text) || (j == longest && w.text.count >= 8)))
            }
            var item = Item(id: ids.uuid(), name: "Caption \(i + 1)", range: TimeRange(start: start, end: end),
                            content: .caption(CaptionContent(words: words, style: styleName)), origin: .auto(pass: "captions"))
            item.transform.position = .constant(style.position)
            items.append(item)
        }
        return items.filter { !$0.range.isEmpty }
    }

    /// Short-form captions drop trailing commas/periods (keep ? and !) when styled in caps.
    static func display(_ text: String, style: TextStyle) -> String {
        guard style.uppercase else { return text }
        var t = text
        while let last = t.last, ",.;:".contains(last) { t.removeLast() }
        return t.isEmpty ? text : t
    }

    static func isEmphasis(_ text: String) -> Bool {
        text.contains { $0.isNumber } || text.hasSuffix("!") || (text.count >= 2 && text == text.uppercased() && text.contains { $0.isLetter })
    }
}

enum Visual {
    /// Jump-cut zoom: alternate items get a tighter framing, and long items get a slow push-in.
    static func punchIns(_ items: [Item], rule: PunchInRule) -> (items: [Item], count: Int) {
        var out = items
        var parity = 0, count = 0
        for i in out.indices {
            let d = out[i].range.duration.seconds
            guard d >= 1.0 else { continue }
            let base = parity % 2 == 1 ? rule.zoom : 1.0
            parity += 1
            if base > 1 { count += 1 }
            if d >= rule.minSpacing * 1.5 {
                out[i].transform.zoom = .keyframes([Keyframe(.zero, base, .easeInOut), Keyframe(out[i].range.duration, base * 1.05)])
            } else if base != 1 {
                out[i].transform.zoom = .constant(base)
            }
        }
        return (out, count)
    }

    /// Keeps the speaker's face in frame when the source is cropped to the slot (e.g. 16:9 → 9:16):
    /// smoothed face centres become `focus` keyframes, simplified with Ramer–Douglas–Peucker.
    static func reframe(_ item: Item, faces: FaceTrack, sourceAspect: Double, boxAspect: Double) -> Item {
        guard abs(sourceAspect - boxAspect) / boxAspect > 0.02, case .media(let ref) = item.content else { return item }
        let s0 = ref.source.start.seconds, s1 = ref.source.end.seconds
        let samples = faces.samples.filter { $0.time >= s0 - 0.5 && $0.time <= s1 + 0.5 }
        guard !samples.isEmpty else { return item }
        // Exponential smoothing (time constant ~0.6 s) with a small dead zone to avoid jitter.
        var points: [(t: Double, x: Double, y: Double)] = []
        var x = samples[0].rect.center.x, y = samples[0].rect.y + samples[0].rect.height * 0.4
        var lastT = samples[0].time
        for s in samples {
            let tx = s.rect.center.x, ty = s.rect.y + s.rect.height * 0.4   // a little headroom above the face centre
            let alpha = 1 - exp(-(s.time - lastT) / 0.6)
            if abs(tx - x) > 0.02 { x += (tx - x) * alpha }
            if abs(ty - y) > 0.02 { y += (ty - y) * alpha }
            lastT = s.time
            points.append((s.time, x, y))
        }
        let simplified = rdp(points, epsilon: 0.01)
        var out = item
        let keys = simplified.map { p in
            Keyframe(RationalTime(seconds: min(max(p.t - s0, 0), s1 - s0)), NormPoint(p.x, p.y), .easeInOut)
        }
        var deduped: [Keyframe<NormPoint>] = []
        for k in keys where deduped.last.map({ $0.time < k.time }) ?? true { deduped.append(k) }
        out.transform.focus = deduped.count == 1 ? .constant(deduped[0].value) : Param.from(deduped)
        return out
    }

    static func rdp(_ p: [(t: Double, x: Double, y: Double)], epsilon: Double) -> [(t: Double, x: Double, y: Double)] {
        guard p.count > 2 else { return p }
        let a = p[0], b = p[p.count - 1]
        var maxD = 0.0, index = 0
        for i in 1..<(p.count - 1) {
            let u = (p[i].t - a.t) / max(b.t - a.t, 1e-9)
            let ix = a.x + (b.x - a.x) * u, iy = a.y + (b.y - a.y) * u
            let d = max(abs(p[i].x - ix), abs(p[i].y - iy))
            if d > maxD { maxD = d; index = i }
        }
        if maxD <= epsilon { return [a, b] }
        let left = rdp(Array(p[0...index]), epsilon: epsilon), right = rdp(Array(p[index...]), epsilon: epsilon)
        return left.dropLast() + right
    }
}

/// Re-splitting existing captions into pages after the user changes "words per caption" (or edits a lot of text):
/// the same paging rules as the draft, applied to the words already on the track.
public enum CaptionPaging {
    /// New caption items for `captions` (one track's pages, any order), paged for `style`. Word timing, emphasis
    /// and the user's text edits are kept; disabled pages are left out.
    public static func repage(_ captions: [Item], styleName: String, style: TextStyle, rate: FrameRate) -> [Item] {
        var words: [TimedWord] = []
        for item in captions.sorted(by: { $0.start < $1.start }) where item.enabled {
            guard case .caption(let c) = item.content else { continue }
            for w in c.words {
                words.append(TimedWord(text: w.text, start: (item.start + w.start).seconds, end: (item.start + w.end).seconds,
                                       isFiller: false, emphasis: w.emphasis))
            }
        }
        guard !words.isEmpty else { return [] }
        var ids = IDGenerator(seed: stableHash("repage|\(styleName)|\(words.count)|\(words[0].start)"))
        return Captions.items(words: words, styleName: styleName, style: style, rate: rate, ids: &ids)
    }
}
