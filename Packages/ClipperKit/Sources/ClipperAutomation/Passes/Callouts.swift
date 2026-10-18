import ClipperCore
import Foundation

extension Visual {
    /// The keywords worth calling out, in time order, at least `rule.minSpacing` apart. None in the first 2.5 s, where
    /// the title is, or the last second.
    static func calloutWords(_ words: [TimedWord], rule: CalloutRule, duration: Double) -> [TimedWord] {
        var picked: [TimedWord] = []
        for w in words.sorted(by: { $0.start < $1.start })
        where !w.isFiller && w.cue.contains(.keyword) && w.start >= 2.5 && w.start <= duration - 1
            && w.start - (picked.last?.start ?? -.infinity) >= rule.minSpacing {
            picked.append(w)
        }
        return picked
    }

    /// One text item per word in `words`, from `calloutWords`.
    static func callouts(_ words: [TimedWord], rule: CalloutRule, styles: [String: TextStyle], rate: FrameRate,
                         duration: Double, ids: inout IDGenerator) -> [Item] {
        guard let style = styles[rule.style] else { return [] }
        var items: [Item] = []
        for w in words {
            let start = RationalTime.frames(w.start, rate), end = RationalTime.frames(min(w.start + rule.seconds, duration), rate)
            guard end > start else { continue }
            let text = calloutText(w.text) + (w.emoji.map { " " + $0 } ?? "")
            var item = Item(id: ids.uuid(), name: "Callout \(items.count + 1)", range: TimeRange(start: start, end: end),
                            content: .text(TextContent(text: text, style: rule.style)), transform: .fullFrame,
                            fadeIn: RationalTime.frames(0.08, rate), fadeOut: RationalTime.frames(0.2, rate), origin: .auto(pass: "callouts"))
            item.transform.position = .constant(style.position)
            items.append(item)
        }
        return items
    }

    /// The word as spoken, without trailing punctuation ("49%" keeps its sign).
    static func calloutText(_ text: String) -> String {
        var t = Substring(text)
        while let c = t.last, c != "%", c.unicodeScalars.allSatisfy(CharacterSet.punctuationCharacters.contains) { t.removeLast() }
        return t.isEmpty ? text : String(t)
    }
}
