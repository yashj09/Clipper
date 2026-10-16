import AppKit
import ClipperCore
import ClipperEngine
import SwiftUI

/// Direct manipulation on the picture, like Premiere's Program Monitor: click something in the viewer to select it, then
/// drag it to move, drag a corner to resize (⌥: zoom inside its frame instead), drag the round handle to rotate
/// (⇧ snaps to 15°), or pinch to resize. Every change is an ordinary undoable edit, keyframe-aware like the panel.
struct ViewerOverlay: View {
    @Bindable var editor: EditorModel
    @State private var drag: Drag?
    @State private var pinchStart: (id: ItemID, scale: Double)?

    private enum Mode { case move, scale, zoom, rotate, none }

    private struct Drag {
        var mode: Mode
        var id: ItemID
        var local: RationalTime?
        var position: NormPoint
        var scale: Double
        var rotation: Double
        var zoom: Double
        var center: CGPoint
        var start: CGPoint
    }

    static let handleRadius: CGFloat = 5
    static let grab: CGFloat = 10
    static let rotateOffset: CGFloat = 26
    /// Space kept round the picture for handles (the viewer pads the picture by this).
    static let margin: CGFloat = 16

    /// Where the picture sits in the overlay (aspect-fit inside the margin), and view points per canvas pixel.
    private func picture(in size: CGSize) -> (origin: CGPoint, size: CGSize, k: CGFloat) {
        let area = CGSize(width: max(1, size.width - 2 * Self.margin), height: max(1, size.height - 2 * Self.margin))
        let aspect = CGFloat(editor.timeline.canvas.aspect)
        let w = min(area.width, area.height * aspect), h = w / aspect
        let origin = CGPoint(x: (size.width - w) / 2, y: (size.height - h) / 2)
        return (origin, CGSize(width: w, height: h), w / CGFloat(max(1, editor.timeline.canvas.width)))
    }

    var body: some View {
        GeometryReader { geo in
            let pic = picture(in: geo.size)
            let quad = selected.flatMap { quad(of: $0, pic) }
            ZStack {
                Color.clear.contentShape(Rectangle())
                if let quad, !editor.player.isPlaying {
                    outline(quad, bounds: geo.size)
                }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in dragChanged(v, pic, bounds: geo.size) }
                .onEnded { v in dragEnded(v) })
            .simultaneousGesture(MagnifyGesture()
                .onChanged { v in pinch(v.magnification) }
                .onEnded { _ in pinchStart = nil; editor.endGesture() })
        }
    }

    // MARK: Drawing

    @ViewBuilder private func outline(_ q: [CGPoint], bounds: CGSize) -> some View {
        let rotate = rotateHandle(q, bounds: bounds)
        let topMid = CGPoint(x: (q[0].x + q[1].x) / 2, y: (q[0].y + q[1].y) / 2)
        Path { p in
            p.move(to: q[0]); p.addLine(to: q[1]); p.addLine(to: q[3]); p.addLine(to: q[2]); p.closeSubpath()
            p.move(to: topMid); p.addLine(to: rotate)
        }
        .stroke(Color.accentColor, lineWidth: 1.5)
        .shadow(color: .black.opacity(0.6), radius: 1)
        ForEach(0..<4, id: \.self) { i in
            Rectangle().fill(Color.white).overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1.5))
                .frame(width: Self.handleRadius * 2, height: Self.handleRadius * 2)
                .position(q[i])
        }
        Circle().fill(Color.white).overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
            .frame(width: Self.handleRadius * 2 + 2, height: Self.handleRadius * 2 + 2)
            .position(rotate)
    }

    /// Out from the middle of the top edge — or inward when that would leave the viewer (a full-frame clip).
    private func rotateHandle(_ q: [CGPoint], bounds: CGSize) -> CGPoint {
        let c = center(q)
        let m = CGPoint(x: (q[0].x + q[1].x) / 2, y: (q[0].y + q[1].y) / 2)
        let dx = m.x - c.x, dy = m.y - c.y, len = max(hypot(dx, dy), 0.001)
        let out = CGPoint(x: m.x + dx / len * Self.rotateOffset, y: m.y + dy / len * Self.rotateOffset)
        let inside = out.x >= 6 && out.y >= 6 && out.x <= bounds.width - 6 && out.y <= bounds.height - 6
        return inside ? out : CGPoint(x: m.x - dx / len * Self.rotateOffset, y: m.y - dy / len * Self.rotateOffset)
    }

    private func center(_ q: [CGPoint]) -> CGPoint {
        CGPoint(x: q.map(\.x).reduce(0, +) / 4, y: q.map(\.y).reduce(0, +) / 4)
    }

    // MARK: Model

    /// The single selected item on a visual track, under the playhead.
    private var selected: Item? {
        guard editor.selection.count == 1, let id = editor.selection.first, let item = editor.timeline.item(id),
              item.range.contains(editor.playhead) || item.end == editor.playhead,
              editor.timeline.tracks.first(where: { $0.items.contains { $0.id == id } })?.kind.isVisual == true else { return nil }
        return item
    }

    private func quad(of item: Item, _ pic: (origin: CGPoint, size: CGSize, k: CGFloat)) -> [CGPoint]? {
        ViewerGeometry.quad(of: item, in: editor.timeline, assets: editor.assets, at: editor.playhead)?
            .map { CGPoint(x: pic.origin.x + CGFloat($0.x) * pic.k, y: pic.origin.y + CGFloat($0.y) * pic.k) }
    }

    private var half: RationalTime { RationalTime(seconds: editor.timeline.canvas.frameRate.frameDuration.seconds / 2) }

    private func localTime(_ item: Item) -> RationalTime? {
        let t = editor.playhead - item.start
        return t >= .zero && t <= item.range.duration ? t : nil
    }

    // MARK: Gestures

    private func dragChanged(_ v: DragGesture.Value, _ pic: (origin: CGPoint, size: CGSize, k: CGFloat), bounds: CGSize) {
        if drag == nil { drag = begin(at: v.startLocation, pic, bounds: bounds) }
        let size = pic.size
        // Nothing changes until the pointer actually moves (a click only selects).
        guard let d = drag, d.mode != .none, hypot(v.translation.width, v.translation.height) >= 1 else { return }
        let local = d.local, half = half, id = d.id
        switch d.mode {
        case .move:
            var p = NormPoint(d.position.x + Double(v.translation.width / size.width), d.position.y + Double(v.translation.height / size.height))
            // Snap to the centre lines, like Premiere's guides.
            if abs(p.x - 0.5) < 0.01 { p.x = 0.5 }
            if abs(p.y - 0.5) < 0.01 { p.y = 0.5 }
            let value = p
            editor.perform(ModifyItem(id, name: "Move", coalescingKey: "viewer-move-\(id)") {
                $0.transform.position = $0.transform.position.assigning(value, at: local, tolerance: half)
            })
        case .scale, .zoom:
            let d0 = max(hypot(d.start.x - d.center.x, d.start.y - d.center.y), 1)
            let ratio = Double(hypot(v.location.x - d.center.x, v.location.y - d.center.y) / d0)
            if d.mode == .scale {
                let s = min(max(d.scale * ratio, 0.05), 10)
                editor.perform(ModifyItem(id, name: "Scale", coalescingKey: "viewer-scale-\(id)") {
                    $0.transform.scale = $0.transform.scale.assigning(s, at: local, tolerance: half)
                })
            } else {
                let z = min(max(d.zoom * ratio, 1), 8)
                editor.perform(ModifyItem(id, name: "Zoom", coalescingKey: "viewer-zoom-\(id)") {
                    $0.transform.zoom = $0.transform.zoom.assigning(z, at: local, tolerance: half)
                })
            }
        case .rotate:
            let a0 = atan2(d.start.y - d.center.y, d.start.x - d.center.x)
            let a1 = atan2(v.location.y - d.center.y, v.location.x - d.center.x)
            var r = d.rotation + Double(a1 - a0) * 180 / .pi
            if NSEvent.modifierFlags.contains(.shift) { r = (r / 15).rounded() * 15 }
            r = r.truncatingRemainder(dividingBy: 360)
            if r > 180 { r -= 360 } else if r < -180 { r += 360 }
            let value = r
            editor.perform(ModifyItem(id, name: "Rotate", coalescingKey: "viewer-rotate-\(id)") {
                $0.transform.rotation = $0.transform.rotation.assigning(value, at: local, tolerance: half)
            })
        case .none:
            break
        }
    }

    /// What a press starts: a handle of the selected item, moving it, or selecting (and moving) what's under the pointer.
    private func begin(at p: CGPoint, _ pic: (origin: CGPoint, size: CGSize, k: CGFloat), bounds: CGSize) -> Drag {
        editor.player.isPlaying ? editor.player.pause() : ()
        func state(_ item: Item, _ mode: Mode, _ q: [CGPoint]) -> Drag {
            let local = localTime(item), t = local ?? .zero
            return Drag(mode: mode, id: item.id, local: local, position: item.transform.position.value(at: t),
                        scale: item.transform.scale.value(at: t), rotation: item.transform.rotation.value(at: t),
                        zoom: item.transform.zoom.value(at: t), center: center(q), start: p)
        }
        if let item = selected, let q = quad(of: item, pic) {
            let r = rotateHandle(q, bounds: bounds)
            if hypot(p.x - r.x, p.y - r.y) <= Self.grab { return state(item, .rotate, q) }
            if q.contains(where: { hypot(p.x - $0.x, p.y - $0.y) <= Self.grab }) {
                let zoomable: Bool = switch item.content { case .media, .image: true; default: false }
                return state(item, NSEvent.modifierFlags.contains(.option) && zoomable ? .zoom : .scale, q)
            }
            if ViewerGeometry.contains(q.map { SIMD2(Double($0.x), Double($0.y)) }, SIMD2(Double(p.x), Double(p.y))) {
                return state(item, .move, q)
            }
        }
        let canvasPoint = SIMD2(Double((p.x - pic.origin.x) / pic.k), Double((p.y - pic.origin.y) / pic.k))
        if let hit = ViewerGeometry.item(at: canvasPoint, in: editor.timeline, assets: editor.assets, time: editor.playhead),
           let q = quad(of: hit, pic) {
            editor.selection = [hit.id]
            return state(hit, .move, q)
        }
        return Drag(mode: .none, id: UUID(), local: nil, position: .center, scale: 1, rotation: 0, zoom: 1, center: .zero, start: p)
    }

    private func dragEnded(_ v: DragGesture.Value) {
        // A click on empty picture deselects.
        if drag?.mode == Mode.none, hypot(v.translation.width, v.translation.height) < 3 { editor.selection = [] }
        drag = nil
        editor.endGesture()
    }

    private func pinch(_ magnification: CGFloat) {
        guard let item = selected else { return }
        if pinchStart?.id != item.id {
            pinchStart = (item.id, item.transform.scale.value(at: localTime(item) ?? .zero))
        }
        guard let start = pinchStart?.scale else { return }
        let s = min(max(start * Double(magnification), 0.05), 10), local = localTime(item), half = half, id = item.id
        editor.perform(ModifyItem(id, name: "Scale", coalescingKey: "viewer-scale-\(id)") {
            $0.transform.scale = $0.transform.scale.assigning(s, at: local, tolerance: half)
        })
    }
}
