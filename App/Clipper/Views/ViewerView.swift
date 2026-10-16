import AVKit
import ClipperCore
import SwiftUI

/// The program monitor: our compositor's output via AVPlayer, plus transport controls.
struct ViewerView: View {
    @Bindable var editor: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                // A margin round the picture leaves room for the selection handles; the overlay covers the whole area
                // and lays the handles out over the picture itself.
                PlayerLayerView(player: editor.player.player)
                    .aspectRatio(editor.timeline.canvas.aspect, contentMode: .fit)
                    .padding(ViewerOverlay.margin)
                ViewerOverlay(editor: editor)
                if editor.player.isBuilding && editor.player.player.currentItem == nil {
                    ProgressView().controlSize(.small)
                }
                if let error = editor.player.lastError {
                    Text(error).font(.caption).foregroundStyle(.red).padding(6).background(.black.opacity(0.7)).frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            HStack(spacing: 14) {
                Text(Timecode.string(editor.playhead.seconds, rate: editor.timeline.canvas.frameRate))
                    .font(.system(.body, design: .monospaced))
                Spacer()
                Button { editor.seek(to: .zero) } label: { Image(systemName: "backward.end.fill") }.help("Go to start (Home)")
                Button { editor.step(frames: -1) } label: { Image(systemName: "backward.frame.fill") }.help("Previous frame (←)")
                Button { editor.togglePlay() } label: { Image(systemName: editor.player.isPlaying ? "pause.fill" : "play.fill").frame(width: 20) }
                    .help("Play/Pause (Space)")
                Button { editor.step(frames: 1) } label: { Image(systemName: "forward.frame.fill") }.help("Next frame (→)")
                Spacer()
                if let item = framedItem {
                    Menu {
                        Button("Fill the Frame") { frame(item, fit: .fill) }
                        Button("Fit in the Frame") { frame(item, fit: .fit) }
                        Divider()
                        Button("Reset Position, Size and Rotation") { frame(item, fit: nil) }
                    } label: { Image(systemName: "rectangle.dashed") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Click the picture to select; drag to move, drag a corner to resize (⌥ zooms inside the frame), drag the round handle to rotate, pinch to resize")
                }
                Text(Timecode.string(editor.timeline.duration.seconds, rate: editor.timeline.canvas.frameRate))
                    .font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.bar)
        }
    }
}

extension ViewerView {
    /// The selected clip or still on a visual track (what the frame menu acts on).
    var framedItem: Item? {
        guard editor.selection.count == 1, let id = editor.selection.first, let item = editor.timeline.item(id),
              editor.timeline.tracks.first(where: { $0.items.contains { $0.id == id } })?.kind.isVisual == true else { return nil }
        switch item.content { case .media, .image: return item; default: return nil }
    }

    func frame(_ item: Item, fit: FitMode?) {
        editor.perform(ModifyItem(item.id, name: fit == nil ? "Reset Motion" : "Frame Clip") { i in
            let box = i.transform.box, crop = i.transform.crop, flipH = i.transform.flipH, flipV = i.transform.flipV
            var t = Transform.fullFrame
            t.box = box; t.crop = crop; t.flipH = flipH; t.flipV = flipV
            t.fit = fit ?? i.transform.fit
            i.transform = t
        })
    }
}

/// A plain AVPlayerLayer host (no system controls; Clipper has its own transport).
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        view.layer = layer
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view.layer as? AVPlayerLayer)?.player = player
    }
}
