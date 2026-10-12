import ClipperCore
import Foundation

/// Converts Clipper's normalized transform model into Final Cut Pro's `adjust-transform` / `adjust-crop` values.
///
/// ## Coordinate systems
/// **Clipper** (`Transform`, mirrored from `LayerGeometry.media` in the Engine): the source (display-oriented,
/// `sw × sh` px) is cropped by `crop`, tightened by `zoom` around `focus`, and fitted (`fill`/`fit`/`stretch`) into a
/// *box* of `box · canvas · scale` pixels, whose centre sits at `position · canvas` (y down) and which is rotated
/// `rotation` degrees clockwise. The result: a visible source rect `R` (source px) drawn as a quad of size `q`
/// centred at `P`.
///
/// **Final Cut Pro**: the source is first *conformed* with "Fit" (the default when there's no `adjust-conform`), i.e.
/// scaled by `c = min(W/sw, H/sh)` and centred in the `W × H` frame. `adjust-crop mode="trim"` then removes edges
/// (values are percentages of the frame height, measured on the conformed image), and `adjust-transform` scales about
/// the image centre (anchor `0 0`), rotates counter-clockwise by `rotation` degrees, and translates by `position`,
/// where position is a percentage of the frame **height**, origin at the frame centre, **y up**:
/// a 1080-high frame with `position="10 10"` moves 108 px right and 108 px up.
///
/// ## Mapping (per sample time)
/// - `S = (q.x / (R.w·c), q.y / (R.h·c))` — scale so the visible rect lands at the quad's size (`S.x == S.y` except
///   for `stretch`).
/// - `v = S ⊙ cR`, where `cR` is R's centre relative to the conformed image centre, in frame px (y down), rotated
///   clockwise by θ: `rv = (v.x cosθ − v.y sinθ, v.x sinθ + v.y cosθ)`.
/// - `d = P − (W/2, H/2) − rv` (frame px, y down) → FCP `position = (100·d.x/H, −100·d.y/H)`.
/// - FCP `rotation = −θ` (Clipper is clockwise, FCP counter-clockwise).
/// - A trim is emitted only when `R` isn't the whole source **and** the quad doesn't cover the frame (a PiP); for
///   full-frame layers the unwanted source simply falls outside the frame, so animated zoom/focus stays exact.
///   `trim = (R.minX·c, R.minY·c, (sw−R.maxX)·c, (sh−R.maxY)·c) / H · 100` (left, top, right, bottom).
///
/// Text layers: Basic Title renders text centred in the frame, so only `position`, `scale` and `rotation` apply.
enum FCPGeometry {
    struct Sample {
        var positionX: Double, positionY: Double
        var scaleX: Double, scaleY: Double
        var rotation: Double
        /// Visible source rect in source pixels (media only).
        var visible: (x: Double, y: Double, w: Double, h: Double)
        /// Whether the drawn quad covers the whole frame.
        var coversFrame: Bool

        var isIdentity: Bool {
            abs(positionX) < 1e-6 && abs(positionY) < 1e-6 && abs(scaleX - 1) < 1e-6 && abs(scaleY - 1) < 1e-6
                && abs(rotation) < 1e-6
        }
    }

    struct Frame { var width: Double; var height: Double }

    /// FCP transform of a media/image layer at item-relative time `t`.
    static func media(_ tr: Transform, at t: RationalTime, frame: Frame, source: Frame) -> Sample {
        let W = frame.width, H = frame.height
        let sw = max(source.width, 1), sh = max(source.height, 1)
        let s = tr.scale.value(at: t), zoom = max(tr.zoom.value(at: t), 0.01)
        let boxW = tr.box.width * W * s, boxH = tr.box.height * H * s
        let crop = tr.crop
        var visW = crop.width * sw / zoom, visH = crop.height * sh / zoom
        var qW = boxW, qH = boxH
        switch tr.fit {
        case .fill:
            let boxAspect = boxW / max(boxH, 1e-9)
            if visW / visH > boxAspect { visW = visH * boxAspect } else { visH = visW / boxAspect }
        case .fit:
            let k = min(boxW / visW, boxH / visH)
            qW = visW * k; qH = visH * k
        case .stretch:
            break
        }
        let focus = tr.focus.value(at: t)
        let cropX = crop.x * sw, cropY = crop.y * sh, cropW = crop.width * sw, cropH = crop.height * sh
        let ox = min(max(focus.x * sw - visW / 2, cropX), cropX + cropW - visW)
        let oy = min(max(focus.y * sh - visH / 2, cropY), cropY + cropH - visH)

        let c = min(W / sw, H / sh)
        let sx = qW / max(visW * c, 1e-9), sy = qH / max(visH * c, 1e-9)
        let crX = (ox + visW / 2 - sw / 2) * c, crY = (oy + visH / 2 - sh / 2) * c
        let deg = tr.rotation.value(at: t)
        let theta = deg * .pi / 180
        let vx = sx * crX, vy = sy * crY
        let rvx = vx * cos(theta) - vy * sin(theta), rvy = vx * sin(theta) + vy * cos(theta)
        let p = tr.position.value(at: t)
        let dx = p.x * W - W / 2 - rvx, dy = p.y * H - H / 2 - rvy

        let eps = 0.5   // px
        let axisAligned = abs(deg.truncatingRemainder(dividingBy: 360)) < 1e-9
        let covers = axisAligned && p.x * W - qW / 2 <= eps && p.x * W + qW / 2 >= W - eps
            && p.y * H - qH / 2 <= eps && p.y * H + qH / 2 >= H - eps
        return Sample(positionX: 100 * dx / H, positionY: -100 * dy / H, scaleX: sx, scaleY: sy, rotation: -deg,
                      visible: (ox, oy, visW, visH), coversFrame: covers)
    }

    /// FCP transform of a title layer (text drawn centred in the frame).
    static func text(_ tr: Transform, at t: RationalTime, frame: Frame) -> Sample {
        let p = tr.position.value(at: t), s = tr.scale.value(at: t), deg = tr.rotation.value(at: t)
        let dx = (p.x - 0.5) * frame.width, dy = (p.y - 0.5) * frame.height
        return Sample(positionX: 100 * dx / frame.height, positionY: -100 * dy / frame.height, scaleX: s, scaleY: s,
                      rotation: -deg, visible: (0, 0, 0, 0), coversFrame: false)
    }

    /// Trim insets (left, top, right, bottom) as percentages of the frame height, or nil when nothing is trimmed.
    static func trim(_ sample: Sample, frame: Frame, source: Frame) -> (left: Double, top: Double, right: Double, bottom: Double)? {
        let sw = max(source.width, 1), sh = max(source.height, 1)
        let c = min(frame.width / sw, frame.height / sh)
        let v = sample.visible
        let k = c / frame.height * 100
        let l = v.x * k, t = v.y * k, r = (sw - v.x - v.w) * k, b = (sh - v.y - v.h) * k
        guard max(l, t, r, b) > 1e-4 else { return nil }
        return (max(l, 0), max(t, 0), max(r, 0), max(b, 0))
    }
}
