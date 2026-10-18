import ClipperCore
import Foundation

extension Visual {
    /// Transitions into primary items that start on a cut (`cuts`, timeline seconds). A chapter at `chapters` (from 1 s
    /// on) marks the cut nearest it within a second: a chapter marker sits on its first word, which the silence cut's
    /// padding puts just after the cut. Every `montageEvery`-th cut
    /// dissolves, slipping to the next cut when the item is under twice the dissolve or follows a transition. An item
    /// that already has a transition (the hook's flash) keeps it.
    static func transitions(_ items: [Item], cuts: [Double], chapters: [RationalTime], rule: TransitionRule,
                            rate: FrameRate) -> (items: [Item], added: Int) {
        var out = items
        var added = 0
        let isCut = out.map { item in cuts.contains { abs($0 - item.start.seconds) < 1e-9 } }
        if let kind = rule.chapters {
            for t in chapters where t.seconds >= 1 {
                guard let i = out.indices.filter({ isCut[$0] && abs(out[$0].start.seconds - t.seconds) <= 1 })
                    .min(by: { abs(out[$0].start.seconds - t.seconds) < abs(out[$1].start.seconds - t.seconds) }),
                      out[i].transition == nil else { continue }
                out[i].transition = Transition(kind, duration: RationalTime.frames(rule.chapterSeconds, rate))
                added += 1
            }
        }
        if let every = rule.montageEvery, every > 0 {
            let d = RationalTime.frames(rule.montageSeconds, rate)
            var since = 0
            for i in out.indices where isCut[i] {
                since += 1
                guard since >= every, i > 0, out[i].transition == nil, out[i].range.duration >= d + d,
                      out[i - 1].transition == nil else { continue }
                out[i].transition = Transition(.crossDissolve, duration: d)
                added += 1
                since = 0
            }
        }
        return (out, added)
    }
}
