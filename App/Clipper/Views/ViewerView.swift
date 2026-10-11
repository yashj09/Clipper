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
                PlayerLayerView(player: editor.player.player)
                    .aspectRatio(editor.timeline.canvas.aspect, contentMode: .fit)
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
                Text(Timecode.string(editor.timeline.duration.seconds, rate: editor.timeline.canvas.frameRate))
                    .font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.bar)
        }
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
