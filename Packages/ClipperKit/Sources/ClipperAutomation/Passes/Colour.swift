import ClipperCore
import Foundation

extension Visual {
    /// Each clip's suggested grade on its items on the picture tracks. An item someone already graded keeps its grade.
    /// `matched` counts the clips whose grade changes anything.
    static func colour(_ tracks: [Track], clips: [ClipInput], rule: ColorRule) -> (tracks: [Track], matched: Int) {
        var grade: [AssetID: ColorAdjust] = [:]
        for clip in clips {
            if let stats = clip.analysis.color { grade[clip.asset.id] = ColorAdjust.suggested(for: stats, look: rule.look) }
        }
        var matched: Set<AssetID> = []
        var out = tracks
        for t in out.indices where out[t].kind == .video || out[t].kind == .overlay {
            for i in out[t].items.indices {
                guard out[t].items[i].color.isNone, let asset = out[t].items[i].content.mediaRef?.asset,
                      let g = grade[asset], !g.isNone else { continue }
                out[t].items[i].color = g
                matched.insert(asset)
            }
        }
        return (out, matched.count)
    }
}
