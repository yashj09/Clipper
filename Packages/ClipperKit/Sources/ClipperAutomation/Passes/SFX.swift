import ClipperCore
import Foundation

extension Visual {
    /// One item per moment (the hook's cut, callouts, emphasis zooms; timeline seconds), each playing its effect's whole
    /// file, cut short at `duration`. None in the first 0.3 s, and none within 0.4 s of the one before: the earlier
    /// moment wins, and at the same time the hook, then a callout. Moments whose effect has no asset are skipped.
    static func sfxItems(zooms: [Double], callouts: [Double], hook: Double?, rule: SFXRule, assets: [SoundEffect: MediaAsset],
                         duration: Double, rate: FrameRate, ids: inout IDGenerator) -> [Item] {
        var moments: [(time: Double, effect: SoundEffect)] = []
        if let e = rule.onHook, let hook { moments.append((hook, e)) }
        if let e = rule.onCallout { moments += callouts.map { ($0, e) } }
        if let e = rule.onZoom { moments += zooms.map { ($0, e) } }
        let ordered = moments.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
        var items: [Item] = []
        var last = -Double.infinity
        for m in ordered where m.time >= 0.3 && m.time - last >= 0.4 {
            guard let asset = assets[m.effect] else { continue }
            let start = RationalTime.frames(m.time, rate)
            // Floored, so the source never runs past the end of the file.
            let end = RationalTime(seconds: min(start.seconds + asset.info.duration.seconds, duration)).floorToFrame(rate)
            guard end > start else { continue }
            let range = TimeRange(start: start, end: end)
            items.append(Item(id: ids.uuid(), name: asset.name, range: range,
                              content: .media(MediaRef(asset: asset.id, source: TimeRange(start: .zero, duration: range.duration))),
                              gain: .constant(rule.gain), origin: .auto(pass: "sfx")))
            last = m.time
        }
        return items
    }
}
