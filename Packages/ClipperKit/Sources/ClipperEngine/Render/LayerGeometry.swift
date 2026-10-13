import ClipperCore
import Foundation
import simd

/// Pure geometry: where a layer's quad lands on the canvas and which part of the source it shows.
/// Kept free of Metal/AVFoundation so it is unit-testable.
public struct LayerGeometry: Equatable, Sendable {
    /// Quad corners in canvas pixels (y down): top-left, top-right, bottom-left, bottom-right.
    public var corners: [SIMD2<Double>]
    /// Visible region of the (display-oriented) source, normalized.
    public var sourceRect: NormRect

    /// Media and images: fit the source into the item's box, apply crop/zoom/focus inside it, then scale and rotate the box.
    public static func media(transform tr: Transform, at t: RationalTime, canvas: SIMD2<Double>,
                             sourceSize: SIMD2<Double>) -> LayerGeometry {
        let scale = tr.scale.value(at: t), zoom = max(tr.zoom.value(at: t), 0.01)
        let box = SIMD2(tr.box.width * canvas.x, tr.box.height * canvas.y) * scale
        let focus = tr.focus.value(at: t)

        // Visible source region: the static crop, tightened by zoom around the focus point.
        let crop = tr.crop
        var vis = SIMD2(crop.width * sourceSize.x, crop.height * sourceSize.y) / zoom
        var quad = box
        switch tr.fit {
        case .fill:
            let boxAspect = box.x / max(box.y, 1e-9)
            if vis.x / vis.y > boxAspect { vis.x = vis.y * boxAspect } else { vis.y = vis.x / boxAspect }
        case .fit:
            let k = min(box.x / vis.x, box.y / vis.y)
            quad = vis * k
        case .stretch:
            break
        }
        // Centre the visible region on the focus point, clamped inside the crop.
        let cropOrigin = SIMD2(crop.x * sourceSize.x, crop.y * sourceSize.y)
        let cropSize = SIMD2(crop.width * sourceSize.x, crop.height * sourceSize.y)
        var origin = SIMD2(focus.x * sourceSize.x, focus.y * sourceSize.y) - vis / 2
        origin = simd_clamp(origin, cropOrigin, cropOrigin + cropSize - vis)
        let rect = NormRect(x: origin.x / sourceSize.x, y: origin.y / sourceSize.y,
                            width: vis.x / sourceSize.x, height: vis.y / sourceSize.y)
        return LayerGeometry(corners: quadCorners(size: quad, transform: tr, at: t, canvas: canvas), sourceRect: rect)
    }

    /// Text and captions: the texture is already rendered at canvas resolution, so its pixel size is the quad size.
    public static func text(transform tr: Transform, at t: RationalTime, canvas: SIMD2<Double>, textureSize: SIMD2<Double>,
                            extraScale: Double = 1) -> LayerGeometry {
        let size = textureSize * tr.scale.value(at: t) * extraScale
        return LayerGeometry(corners: quadCorners(size: size, transform: tr, at: t, canvas: canvas), sourceRect: .full)
    }

    static func quadCorners(size: SIMD2<Double>, transform tr: Transform, at t: RationalTime, canvas: SIMD2<Double>) -> [SIMD2<Double>] {
        let p = tr.position.value(at: t)
        let center = SIMD2(p.x * canvas.x, p.y * canvas.y)
        let theta = tr.rotation.value(at: t) * .pi / 180
        let ax = SIMD2(cos(theta), sin(theta)) * size.x / 2      // clockwise in y-down space
        let ay = SIMD2(-sin(theta), cos(theta)) * size.y / 2
        return [center - ax - ay, center + ax - ay, center - ax + ay, center + ax + ay]
    }
}

/// Where the timeline's canvas lands in an output frame. When the aspect ratios match (preview at a reduced scale,
/// presets of the canvas's shape) it fills the frame; otherwise it is scaled to fit and centred — letterboxed or
/// pillarboxed — so a preset of another shape never re-crops the layout or distorts text.
public struct CanvasFrame: Equatable, Sendable {
    /// Top-left of the canvas in output pixels (y down).
    public var origin: SIMD2<Double>
    /// Size of the canvas in output pixels.
    public var size: SIMD2<Double>
    /// Output pixels per canvas pixel (text is rasterized at canvas size and scaled by this).
    public var scale: Double

    public var isLetterboxed: Bool { origin != .zero }

    public static func fitting(canvas: SIMD2<Double>, in output: SIMD2<Double>) -> CanvasFrame {
        guard canvas.x > 0, canvas.y > 0, output.x > 0, output.y > 0 else { return CanvasFrame(origin: .zero, size: output, scale: 1) }
        let sx = output.x / canvas.x, sy = output.y / canvas.y
        // Same shape up to rounding (even-sized preview buffers): fill exactly, as before.
        if abs(sx / sy - 1) <= 0.01 { return CanvasFrame(origin: .zero, size: output, scale: sx) }
        let scale = min(sx, sy)
        let size = canvas * scale
        return CanvasFrame(origin: ((output - size) / 2).rounded(.down), size: size, scale: scale)
    }
}

/// Maps display-oriented normalized source coordinates to the stored (natural) texture coordinates.
public struct Orientation: Equatable, Sendable {
    public var rotation: Int
    public var mirrored: Bool
    public init(rotation: Int, mirrored: Bool) { self.rotation = rotation; self.mirrored = mirrored }
    public static let identity = Orientation(rotation: 0, mirrored: false)

    public func textureCoordinate(_ d: SIMD2<Double>) -> SIMD2<Double> {
        let u = mirrored ? 1 - d.x : d.x, v = d.y
        switch rotation {
        case 90: return SIMD2(v, 1 - u)      // displayed rotated 90° clockwise
        case 180: return SIMD2(1 - u, 1 - v)
        case 270: return SIMD2(1 - v, u)
        default: return SIMD2(u, v)
        }
    }
}
