import ClipperCore
import SwiftUI

/// SwiftUI wrapper: pushes model state into the AppKit canvas and turns its gestures into edit commands.
struct TimelineView: NSViewRepresentable {
    @Bindable var editor: EditorModel
    var zoomRequest: ZoomRequest?

    enum ZoomRequest: Equatable { case fit(UUID), zoomIn(UUID), zoomOut(UUID) }

    func makeNSView(context: Context) -> TimelineCanvas {
        let canvas = TimelineCanvas(frame: .zero)
        canvas.delegate = context.coordinator
        DispatchQueue.main.async { canvas.zoomToFit() }
        return canvas
    }

    func updateNSView(_ canvas: TimelineCanvas, context: Context) {
        context.coordinator.editor = editor
        canvas.assets = editor.assets
        canvas.snapping = editor.settings.editing.snapping
        canvas.rippleByDefault = editor.settings.editing.rippleByDefault
        if canvas.timeline != editor.timeline { canvas.timeline = editor.timeline }
        canvas.selection = editor.selection
        canvas.playhead = editor.playhead
        if zoomRequest != context.coordinator.lastZoom {
            context.coordinator.lastZoom = zoomRequest
            let mid = canvas.bounds.midX
            switch zoomRequest {
            case .fit: canvas.zoomToFit()
            case .zoomIn: canvas.zoom(by: 1.5, around: mid)
            case .zoomOut: canvas.zoom(by: 1 / 1.5, around: mid)
            case nil: break
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(editor: editor) }

    @MainActor final class Coordinator: TimelineCanvasDelegate {
        var editor: EditorModel
        var lastZoom: ZoomRequest?
        init(editor: EditorModel) { self.editor = editor }

        func timelineSelect(_ ids: Set<ItemID>) { editor.selection = ids }
        func timelineSeek(_ time: RationalTime) { editor.player.isPlaying ? editor.player.pause() : (); editor.seek(to: time) }
        func timelineMove(_ id: ItemID, toTrack: TrackID, start: RationalTime) {
            editor.perform(MoveItem(id, to: toTrack, at: start, mode: .reject))
        }
        func timelineTrim(_ id: ItemID, edge: TrimEdge, to: RationalTime, ripple: Bool) {
            editor.perform(TrimItem(id, edge: edge, to: to, ripple: ripple))
        }
        func timelineKey(_ action: TimelineCanvas.KeyAction) {
            let player = editor.player
            switch action {
            case .playPause: editor.togglePlay()
            case .stop: player.pause()
            case .shuttleForward: player.player.rate = player.isPlaying && player.player.rate >= 1 ? min(player.player.rate * 2, 8) : 1; if !player.isPlaying { player.play() }
            case .shuttleBack: player.pause(); editor.step(frames: -Int(editor.timeline.canvas.frameRate.fps))
            case .stepBack: player.pause(); editor.step(frames: -1)
            case .stepForward: player.pause(); editor.step(frames: 1)
            case .blade: editor.bladeAtPlayhead()
            case .delete: editor.deleteSelection(ripple: false)
            case .rippleDelete: editor.deleteSelection(ripple: true)
            case .home: editor.seek(to: .zero)
            case .end: editor.seek(to: editor.timeline.duration)
            case .zoomFit: break
            }
        }

        func timelineToggle(_ track: TrackID, _ property: TimelineCanvas.TrackToggle) {
            let name = switch property { case .mute: "Toggle Mute"; case .hide: "Toggle Visibility"; case .lock: "Toggle Lock" }
            editor.perform(ModifyTrack(track, name: name) { t in
                switch property {
                case .mute: t.muted.toggle()
                case .hide: t.hidden.toggle()
                case .lock: t.locked.toggle()
                }
            })
        }
    }
}
