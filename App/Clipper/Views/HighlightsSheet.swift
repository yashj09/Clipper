import AVFoundation
import ClipperAutomation
import ClipperCore
import SwiftUI

/// Ranked moments from a long recording; preview, pick, and turn them into shorts.
struct HighlightsSheet: View {
    @Bindable var model: AppModel
    let session: HighlightSession
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<String> = []
    @State private var templateID = "talking-head"
    @State private var previewing: Highlight?
    @State private var player = AVPlayer()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Highlights in \(session.asset.name)").font(.title2.bold())
                Spacer()
                Text(session.rankedBy).font(.caption).foregroundStyle(.secondary)
            }
            HSplitView {
                List(session.highlights) { h in
                    HStack(alignment: .top, spacing: 10) {
                        Toggle("", isOn: Binding(get: { picked.contains(h.id) }, set: { if $0 { picked.insert(h.id) } else { picked.remove(h.id) } }))
                            .labelsHidden()
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(HighlightFinder.clock(h.start)).font(.system(.body, design: .monospaced))
                                Text(String(format: "%.0fs", h.duration)).foregroundStyle(.secondary)
                                ProgressView(value: h.score).frame(width: 60)
                                Text(String(format: "%.2f", h.score)).font(.caption.monospacedDigit())
                            }
                            if let t = h.title { Text("“\(t)”").font(.headline) }
                            Text(h.reason).font(.caption).foregroundStyle(.orange)
                            Text(h.text).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                        Spacer()
                        Button { preview(h) } label: { Image(systemName: previewing == h ? "speaker.wave.2.fill" : "play.circle") }
                            .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
                .frame(minWidth: 460)
                PlayerLayerView(player: player).frame(minWidth: 220).background(.black)
            }
            HStack {
                Picker("Template", selection: $templateID) { ForEach(model.templates) { Text($0.name).tag($0.id) } }.frame(width: 260)
                Spacer()
                Button("Cancel") { player.pause(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create \(picked.count) Short\(picked.count == 1 ? "" : "s")") {
                    player.pause()
                    let chosen = session.highlights.filter { picked.contains($0.id) }
                    let template = model.templates.first { $0.id == templateID } ?? BuiltIns.talkingHead
                    dismiss()
                    Task { await model.createShorts(from: session, highlights: chosen, template: template) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 900, height: 620)
        .onAppear {
            picked = Set(session.highlights.prefix(5).map(\.id))
            templateID = session.asset.info.displayAspect > 1.2 && session.analysis.transcript?.words.isEmpty != false ? "gameplay" : model.settings.automation.defaultTemplate
            player.replaceCurrentItem(with: AVPlayerItem(url: session.asset.renderURL))
        }
        .onDisappear { player.pause() }
    }

    private func preview(_ h: Highlight) {
        previewing = h
        let item = player.currentItem
        item?.forwardPlaybackEndTime = CMTime(seconds: h.end, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: h.start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }
}

/// Result of a highlight search, kept while the sheet is open.
struct HighlightSession: Identifiable {
    let id = UUID()
    let asset: MediaAsset
    let analysis: AssetAnalysis
    let highlights: [Highlight]
    let rankedBy: String
}
