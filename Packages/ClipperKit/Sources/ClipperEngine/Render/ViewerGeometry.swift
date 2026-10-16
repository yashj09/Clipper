import ClipperCore
import Foundation

/// Where items are drawn on the frame, for direct manipulation in the viewer (Premiere's Program Monitor handles):
/// the same layout maths as the compositor, in canvas pixels (y down).
public enum ViewerGeometry {
    /// The quad (top-left, top-right, bottom-left, bottom-right) of `item` at timeline time `time`, or nil for items
    /// with nothing to show (audio, missing media, empty text).
    public static func quad(of item: Item, in timeline: Timeline, assets: [AssetID: MediaAsset], at time: RationalTime) -> [SIMD2<Double>]? {
        let canvas = SIMD2(Double(timeline.canvas.width), Double(timeline.canvas.height))
        let local = time - item.start
        switch item.content {
        case .media(let ref):
            guard let info = assets[ref.asset]?.info, info.hasVideo else { return nil }
            return LayerGeometry.media(transform: item.transform, at: local, canvas: canvas,
                                       sourceSize: SIMD2(Double(info.displayWidth), Double(info.displayHeight))).corners
        case .image(let id):
            guard let info = assets[id]?.info else { return nil }
            return LayerGeometry.media(transform: item.transform, at: local, canvas: canvas,
                                       sourceSize: SIMD2(Double(info.displayWidth), Double(info.displayHeight))).corners
        case .solid:
            return LayerGeometry.media(transform: item.transform, at: local, canvas: canvas, sourceSize: canvas).corners
        case .text(let t):
            return textQuad(t.text.split(separator: " ").map(String.init), style: t.style, item: item, timeline: timeline, local: local)
        case .caption(let c):
            return textQuad(c.words.map(\.text), style: c.style, item: item, timeline: timeline, local: local)
        }
    }

    private static func textQuad(_ words: [String], style key: String, item: Item, timeline: Timeline, local: RationalTime) -> [SIMD2<Double>]? {
        guard !words.isEmpty, let style = timeline.styles[key] else { return nil }
        let layout = TextRenderer.layout(words: words, style: style, canvasWidth: timeline.canvas.width, canvasHeight: timeline.canvas.height)
        let canvas = SIMD2(Double(timeline.canvas.width), Double(timeline.canvas.height))
        return LayerGeometry.text(transform: item.transform, at: local, canvas: canvas,
                                  textureSize: SIMD2(Double(layout.size.width), Double(layout.size.height))).corners
    }

    /// The topmost visible item drawn at canvas point `p` at `time` (captions and titles above footage), if any.
    public static func item(at p: SIMD2<Double>, in timeline: Timeline, assets: [AssetID: MediaAsset], time: RationalTime) -> Item? {
        for track in timeline.tracks.reversed() where track.kind.isVisual && !track.hidden {
            guard let item = track.items.first(where: { $0.enabled && $0.range.contains(time) }),
                  let quad = quad(of: item, in: timeline, assets: assets, at: time), contains(quad, p) else { continue }
            return item
        }
        return nil
    }

    /// Whether `p` is inside the (possibly rotated) quad.
    public static func contains(_ q: [SIMD2<Double>], _ p: SIMD2<Double>) -> Bool {
        guard q.count == 4 else { return false }
        let poly = [q[0], q[1], q[3], q[2]]   // perimeter order
        var sign = 0.0
        for i in 0..<4 {
            let a = poly[i], b = poly[(i + 1) % 4]
            let cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
            if cross != 0 {
                if sign == 0 { sign = cross } else if (cross > 0) != (sign > 0) { return false }
            }
        }
        return true
    }
}
