import ClipperCore
import SwiftUI

/// SwiftUI wrapper: pushes model state into the AppKit canvas and turns its gestures into edit commands.
struct TimelineView: NSViewRepresentable {
    @Bindable var model: AppModel
    @Bindable var editor: EditorModel

    func makeNSView(context: Context) -> TimelineCanvas {
        let canvas = TimelineCanvas(frame: .zero)
        canvas.delegate = context.coordinator
        DispatchQueue.main.async { canvas.zoomToFit() }
        return canvas
    }

    func updateNSView(_ canvas: TimelineCanvas, context: Context) {
        context.coordinator.model = model
        context.coordinator.editor = editor
        canvas.assets = editor.assets
        canvas.snapping = editor.settings.editing.snapping
        canvas.rippleByDefault = editor.settings.editing.rippleByDefault
        if canvas.timeline != editor.timeline { canvas.timeline = editor.timeline }
        canvas.selection = editor.selection
        canvas.playhead = editor.playhead
        canvas.inPoint = editor.inPoint
        canvas.outPoint = editor.outPoint
        if editor.zoomRequest != context.coordinator.lastZoom {
            context.coordinator.lastZoom = editor.zoomRequest
            let mid = canvas.bounds.midX
            switch editor.zoomRequest {
            case .fit: canvas.zoomToFit()
            case .zoomIn: canvas.zoom(by: 1.5, around: mid)
            case .zoomOut: canvas.zoom(by: 1 / 1.5, around: mid)
            case nil: break
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model, editor: editor) }

    @MainActor final class Coordinator: TimelineCanvasDelegate {
        var model: AppModel
        var editor: EditorModel
        var lastZoom: ZoomRequest?
        init(model: AppModel, editor: EditorModel) { self.model = model; self.editor = editor }

        func timelineSelect(_ ids: Set<ItemID>) { editor.selection = ids }
        func timelineSeek(_ time: RationalTime) { editor.player.isPlaying ? editor.player.pause() : (); editor.seek(to: time) }
        func timelineMove(_ id: ItemID, toTrack: TrackID, start: RationalTime) {
            editor.perform(MoveItem(id, to: toTrack, at: start, mode: .reject))
        }
        func timelineTrim(_ id: ItemID, edge: TrimEdge, to: RationalTime, ripple: Bool) {
            editor.perform(TrimItem(id, edge: edge, to: to, ripple: ripple))
        }
        func timelineAction(_ action: EditorAction) { model.perform(action) }
        func timelineSetSpeed(_ id: ItemID, _ speed: Double) { editor.setSpeed(id, speed) }
        func timelineShortcut(for action: EditorAction) -> KeyShortcut? { model.settings.keyBindings.shortcuts(for: action).first }

        func timelineDropPreview(_ payload: String) -> (duration: RationalTime, kinds: [TrackKind])? {
            BrowserItem(payload: payload).flatMap(model.dropPreview)
        }

        func timelineDrop(_ payload: String, track: TrackID?, at time: RationalTime, insert: Bool) {
            guard let item = BrowserItem(payload: payload) else { return }
            model.drop(item, on: track, at: time, insert: insert)
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
