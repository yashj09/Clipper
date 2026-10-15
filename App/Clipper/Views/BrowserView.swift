import ClipperAutomation
import ClipperCore
import ClipperEngine
import SwiftUI

/// The editor's browser: library media, music and text styles to drag onto the timeline, or to add at the playhead
/// with the connect / insert / append / overwrite buttons (Q / W / E / D).
struct BrowserView: View {
    @Bindable var model: AppModel
    @Bindable var editor: EditorModel
    @State private var tab = Tab.media
    @State private var search = ""

    enum Tab: String, CaseIterable { case media = "Media", music = "Music", titles = "Titles" }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) } }
                .pickerStyle(.segmented).labelsHidden().padding(8)
            TextField("Search", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal, 8).padding(.bottom, 6)
            List(selection: $editor.browserSelection) {
                switch tab {
                case .media:
                    ForEach(model.assets.filter { matches($0.name) }) { asset in
                        row(.asset(asset.id)) { MediaRow(asset: asset) }
                    }
                case .music:
                    ForEach(model.music.filter { matches($0.title) || matches($0.artist) }) { track in
                        row(.music(track.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title).lineLimit(1)
                                Text("\(track.artist) · \(Self.duration(track.duration))\(track.bpm.map { String(format: " · %.0f BPM", $0) } ?? "")")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                case .titles:
                    ForEach(styleNames.filter(matches), id: \.self) { name in
                        row(.title(name)) {
                            HStack {
                                Image(systemName: "textformat").foregroundStyle(.secondary)
                                Text(name)
                            }
                        }
                    }
                }
            }
            .overlay { if isEmpty { Text(emptyText).foregroundStyle(.secondary).font(.callout).multilineTextAlignment(.center).padding() } }
            Divider()
            HStack(spacing: 4) {
                addButton(.connect, "rectangle.stack.badge.plus", .connectToTimeline)
                addButton(.insert, "arrow.right.to.line.compact", .insertAtPlayhead)
                addButton(.append, "text.append", .appendToStoryline)
                addButton(.overwrite, "square.on.square.dashed", .overwriteAtPlayhead)
            }
            .buttonStyle(.borderless)
            .disabled(editor.browserSelection == nil)
            .padding(6)
        }
    }

    private func row<Content: View>(_ item: BrowserItem, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .tag(item)
            .onDrag { NSItemProvider(object: item.payload as NSString) }
            .contextMenu {
                Button("Connect at Playhead") { add(item, .connect) }
                Button("Insert at Playhead") { add(item, .insert) }
                Button("Append to Storyline") { add(item, .append) }
                Button("Overwrite at Playhead") { add(item, .overwrite) }
            }
    }

    private func addButton(_ mode: AddMode, _ symbol: String, _ action: EditorAction) -> some View {
        let key = model.settings.keyBindings.shortcuts(for: action).first.map { " (\($0.display))" } ?? ""
        return Button { model.perform(action) } label: { Image(systemName: symbol).frame(maxWidth: .infinity) }
            .help(action.title + key)
    }

    private func add(_ item: BrowserItem, _ mode: AddMode) {
        editor.browserSelection = item
        model.addBrowserSelection(mode)
    }

    /// Title styles first, then the rest (captions styles work as plain text too).
    private var styleNames: [String] {
        let names = Set(editor.timeline.styles.keys).union(["title-bold", "title-clean"])
        return names.sorted { ($0.contains("title") ? 0 : 1, $0) < ($1.contains("title") ? 0 : 1, $1) }
    }

    private func matches(_ s: String) -> Bool { search.isEmpty || s.localizedCaseInsensitiveContains(search) }

    private var isEmpty: Bool {
        switch tab {
        case .media: model.assets.isEmpty
        case .music: model.music.isEmpty
        case .titles: false
        }
    }

    private var emptyText: String {
        tab == .media ? "Import media from the library to use it here." : "No music yet — add the starter pack or generate some under Music."
    }

    static func duration(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
}

private struct MediaRow: View {
    let asset: MediaAsset
    @State private var thumb: CGImage?

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Color.black
                if let thumb { Image(decorative: thumb, scale: 1).resizable().aspectRatio(contentMode: .fit) }
                else { Image(systemName: asset.info.kind == .audio ? "waveform" : "film").foregroundStyle(.secondary) }
            }
            .frame(width: 52, height: 32).clipShape(RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 2) {
                Text(asset.name).lineLimit(1)
                Text(BrowserView.duration(asset.info.duration.seconds) + (asset.info.hasVideo ? " · \(asset.info.displayWidth)×\(asset.info.displayHeight)" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: asset.id) {
            guard asset.info.hasVideo else { return }
            thumb = await Thumbnailer.shared.thumbnail(asset.proxyURL ?? asset.renderURL, at: min(1, asset.info.duration.seconds / 2), height: 64)
        }
    }
}
