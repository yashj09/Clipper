import ClipperAnalysis
import ClipperAutomation
import ClipperCore
import ClipperEngine
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.section) {
                Section("Library") {
                    Label("Media (\(model.assets.count))", systemImage: "film.stack").tag(AppModel.Section.media)
                    Label("Music (\(model.music.count))", systemImage: "music.note.list").tag(AppModel.Section.music)
                    Label("Templates", systemImage: "rectangle.3.group").tag(AppModel.Section.templates)
                    Label("Publishing", systemImage: "paperplane").tag(AppModel.Section.publishing)
                }
                Section("Projects") {
                    ForEach(model.projects) { p in
                        Label(p.name, systemImage: "film").tag(AppModel.Section.project(p.id))
                            .contextMenu { Button("Delete Project", role: .destructive) { model.delete(p.id) } }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
            .onChange(of: model.section) { _, s in
                if case .project(let id) = s, model.editor?.project.id != id { model.open(id) }
            }
        } detail: {
            Group {
                switch model.section {
                case .media: MediaGridView(model: model)
                case .music: MusicListView(model: model)
                case .templates: TemplatesView(model: model)
                case .publishing: PublishingView(model: model)
                case .project:
                    if let editor = model.editor { EditorView(model: model, editor: editor) } else { ProgressView() }
                }
            }
            .overlay(alignment: .bottom) { if let a = model.activity { ActivityBar(activity: a) } }
        }
        .sheet(item: Binding(get: { model.draftSheet.map(DraftSheetItem.init) }, set: { model.draftSheet = $0?.ids })) { item in
            DraftSheet(model: model, initial: item.ids)
        }
        .sheet(isPresented: $model.exportSheet) { ExportSheet(model: model) }
        .sheet(item: $model.highlightSession) { session in HighlightsSheet(model: model, session: session) }
        .sheet(isPresented: $model.saveTemplateSheet) { SaveTemplateSheet(model: model) }
        .sheet(isPresented: $model.publishSheet) { PublishSheet(model: model) }
        .sheet(item: $model.templateEdit) { req in TemplateEditorSheet(model: model, original: req.template, isNew: req.isNew) }
        .alert("Clipper", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        } message: { Text(model.alert ?? "") }
        .overlay { if let e = model.libraryError { Text(e).padding().background(.red.opacity(0.2)) } }
    }
}

struct DraftSheetItem: Identifiable {
    let ids: [AssetID]
    var id: String { ids.map(\.uuidString).joined() }
}

struct ActivityBar: View {
    let activity: Activity
    var body: some View {
        HStack(spacing: 10) {
            if let p = activity.progress { ProgressView(value: p).frame(width: 140) } else { ProgressView().controlSize(.small) }
            Text(activity.title).bold()
            Text(activity.detail).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .padding(12)
    }
}

// MARK: - Media

struct MediaGridView: View {
    @Bindable var model: AppModel
    @State private var selection = Set<AssetID>()
    @State private var dropTargeted = false

    var body: some View {
        ScrollView {
            if model.assets.isEmpty {
                ContentUnavailableView("No media yet", systemImage: "square.and.arrow.down",
                                       description: Text("Drop clips here or click Import. Files stay where they are; Clipper references them."))
                    .padding(.top, 80)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                ForEach(model.assets) { asset in
                    MediaCard(asset: asset, selected: selection.contains(asset.id))
                        .onTapGesture {
                            if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) {
                                if selection.contains(asset.id) { selection.remove(asset.id) } else { selection.insert(asset.id) }
                            } else { selection = [asset.id] }
                        }
                        .draggable(asset.id.uuidString)
                        .contextMenu {
                            Button("New Draft…") { model.draftSheet = [asset.id] }
                            if asset.info.duration.seconds > 90 {
                                Button("Find Highlights…") { Task { await model.findHighlights(asset) } }
                            }
                        }
                }
            }
            .padding(16)
        }
        .background(dropTargeted ? Color.accentColor.opacity(0.08) : .clear)
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.importFiles(urls) }
            return true
        } isTargeted: { dropTargeted = $0 }
        .toolbar {
            ToolbarItem { Button { model.chooseAndImport() } label: { Label("Import", systemImage: "plus") } }
            ToolbarItem {
                Button {
                    model.draftSheet = model.assets.filter { selection.contains($0.id) }.map(\.id)
                } label: { Label("New Draft", systemImage: "wand.and.stars") }
                    .help("Create an automatic draft from the selected clips")
            }
        }
        .navigationTitle("Media")
    }
}

struct MediaCard: View {
    let asset: MediaAsset
    let selected: Bool
    @State private var thumb: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                Color.black
                if let thumb { Image(decorative: thumb, scale: 1).resizable().aspectRatio(contentMode: .fit) }
                else if asset.info.kind == .audio { Image(systemName: "waveform").font(.largeTitle).foregroundStyle(.secondary) }
            }
            .frame(height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : .clear, lineWidth: 3))
            Text(asset.name).font(.callout).lineLimit(1)
            HStack(spacing: 6) {
                Text(String(format: "%.1fs", asset.info.duration.seconds))
                if asset.info.hasVideo { Text("\(asset.info.displayWidth)×\(asset.info.displayHeight)") }
                if asset.info.transfer != .sdr { Text(asset.info.transfer.rawValue.uppercased()).foregroundStyle(.orange) }
                if asset.info.isVFR { Text("VFR") }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .task(id: asset.id) {
            guard asset.info.hasVideo else { return }
            thumb = await Thumbnailer.shared.thumbnail(asset.renderURL, at: min(1, asset.info.duration.seconds / 2), height: 200)
        }
    }
}

// MARK: - Music and templates

struct MusicListView: View {
    @Bindable var model: AppModel
    @State private var generateSheet = false
    var body: some View {
        Table(model.music) {
            TableColumn("Title", value: \.title)
            TableColumn("Artist", value: \.artist)
            TableColumn("BPM") { Text($0.bpm.map { String(format: "%.0f", $0) } ?? "–") }.width(50)
            TableColumn("Length") { Text(String(format: "%d:%02d", Int($0.duration) / 60, Int($0.duration) % 60)) }.width(60)
            TableColumn("Moods") { Text($0.moods.joined(separator: ", ")) }
            TableColumn("Licence") { t in
                switch t.license { case .ccBy: Text("CC BY"); case .cc0: Text("CC0"); case .owned: Text("Own"); case .generated: Text("Generated") }
            }.width(70)
        }
        .overlay {
            if model.music.isEmpty {
                ContentUnavailableView {
                    Label("No music yet", systemImage: "music.note")
                } description: {
                    Text("Get 24 free tracks (Kevin MacLeod, CC BY 4.0; credits are added to each project automatically), or add your own with `clipper music add`.")
                } actions: {
                    Button("Download free starter pack") { Task { await model.addStarterPack() } }
                }
            }
        }
        .navigationTitle("Music")
        .toolbar {
            ToolbarItem { Button { generateSheet = true } label: { Label("Generate", systemImage: "waveform.badge.plus") }
                .help("Generate royalty-free music on this Mac (ACE-Step)") }
            ToolbarItem { Button { Task { await model.addStarterPack() } } label: { Label("Starter Pack", systemImage: "arrow.down.circle") } }
        }
        .sheet(isPresented: $generateSheet) { GenerateMusicSheet(model: model) }
    }
}

struct GenerateMusicSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = "upbeat lo-fi hip hop, warm keys, soft drums"
    @State private var duration = 60.0
    @State private var useBPM = false
    @State private var bpm = 100.0
    @State private var variations = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Generate music").font(.title2.bold())
            Text("Runs ACE-Step 1.5 (MIT) on this Mac — no attribution needed. The first run downloads about 6.3 GB; generating uses ~11–16 GB of memory while it runs.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Describe the music", text: $prompt, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
            LabeledContent("Length") { HStack { Slider(value: $duration, in: 15...180, step: 15); Text("\(Int(duration)) s").frame(width: 50) } }
            HStack {
                Toggle("Tempo", isOn: $useBPM)
                Slider(value: $bpm, in: 60...180, step: 1).disabled(!useBPM)
                Text("\(Int(bpm)) BPM").frame(width: 70).foregroundStyle(useBPM ? .primary : .secondary)
            }
            Stepper("Takes: \(variations)", value: $variations, in: 1...4)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Generate") {
                    let (p, d, b, v) = (prompt, duration, useBPM ? bpm : nil, variations)
                    dismiss()
                    Task { await model.generateMusic(prompt: p, duration: d, bpm: b, variations: v) }
                }
                .keyboardShortcut(.defaultAction).disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 520)
    }
}

struct TemplatesView: View {
    @Bindable var model: AppModel
    var body: some View {
        let mine = model.userTemplateIDs
        List(model.templates) { t in
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(t.name).font(.headline)
                        if mine.contains(t.id) { Text("yours").font(.caption2).padding(.horizontal, 5).background(Capsule().fill(Color.accentColor.opacity(0.25))) }
                        Text("\(t.canvas.width)×\(t.canvas.height) @ \(t.canvas.frameRate)").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(t.summary).font(.callout).foregroundStyle(.secondary)
                    Text("Slots: " + t.slots.map(\.name).joined(separator: ", ") + (t.rules.captions.map { " · captions: \($0.style)" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Duplicate & Edit…") { model.templateEdit = TemplateEditRequest(template: t, isNew: true) }
                if mine.contains(t.id) {
                    Button("Edit…") { model.templateEdit = TemplateEditRequest(template: t, isNew: false) }
                    Button(role: .destructive) { model.deleteTemplate(t.id) } label: { Image(systemName: "trash") }
                }
            }
            .padding(.vertical, 4)
        }
        .navigationTitle("Templates")
    }
}

// MARK: - Editor

struct EditorView: View {
    @Bindable var model: AppModel
    @Bindable var editor: EditorModel
    @State private var zoom: TimelineView.ZoomRequest? = .fit(UUID())
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        VSplitView {
            HSplitView {
                ViewerView(editor: editor).frame(minWidth: 360, minHeight: 300)
                InspectorView(editor: editor).frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
            }
            TimelineView(editor: editor, zoomRequest: zoom).frame(minHeight: 220, idealHeight: 320)
        }
        .onAppear { editor.undoManager = undoManager }
        .navigationTitle(editor.project.name)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if editor.project.timelines.count > 1 {
                    Picker("Short", selection: Binding(get: { editor.timelineIndex }, set: { editor.selectTimeline($0) })) {
                        ForEach(editor.project.timelines.indices, id: \.self) { Text(editor.project.timelines[$0].name).tag($0) }
                    }
                    .frame(maxWidth: 280)
                }
            }
            ToolbarItemGroup {
                Button { editor.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }.disabled(!editor.history.canUndo)
                    .help(editor.history.undoName.map { "Undo \($0)" } ?? "Undo")
                Button { editor.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }.disabled(!editor.history.canRedo)
                Button { editor.bladeAtPlayhead() } label: { Label("Split", systemImage: "scissors") }.help("Split at playhead (B)")
                Button { editor.deleteSelection(ripple: model.settings.editing.rippleByDefault) } label: { Label("Delete", systemImage: "trash") }
                    .disabled(editor.selection.isEmpty)
                Toggle(isOn: Binding(get: { model.settings.editing.rippleByDefault }, set: { model.settings.editing.rippleByDefault = $0; model.saveSettings() })) {
                    Label("Ripple", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }.help("Ripple edits close gaps (hold ⌥ while trimming to invert)")
                Toggle(isOn: Binding(get: { model.settings.editing.snapping }, set: { model.settings.editing.snapping = $0; model.saveSettings() })) {
                    Label("Snap", systemImage: "arrow.right.to.line")
                }
                Button { zoom = .zoomOut(UUID()) } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
                Button { zoom = .fit(UUID()) } label: { Label("Fit", systemImage: "arrow.left.and.right") }
                Button { zoom = .zoomIn(UUID()) } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
                CaptionsMenu(editor: editor)
                Button { model.saveTemplateSheet = true } label: { Label("Save as Template", systemImage: "rectangle.stack.badge.plus") }
                    .help("Save this layout, titles, captions and music settings as a reusable template")
                Button { model.exportSheet = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                Button { model.publishSheet = true } label: { Label("Publish", systemImage: "paperplane") }
                    .help("Publish or schedule to YouTube, TikTok or Instagram")
            }
        }
    }
}


/// Translate captions on-device and pick which language is burned in.
struct CaptionsMenu: View {
    @Bindable var editor: EditorModel
    @State private var installed: Set<String> = []
    static let languages: [(String, String)] = [("es", "Spanish"), ("fr", "French"), ("de", "German"), ("it", "Italian"),
        ("pt-BR", "Portuguese (Brazil)"), ("hi", "Hindi"), ("ja", "Japanese"), ("ko", "Korean"), ("zh-Hans", "Chinese (Simplified)"),
        ("ar", "Arabic"), ("ru", "Russian"), ("tr", "Turkish"), ("id", "Indonesian"), ("nl", "Dutch")]

    var body: some View {
        let languages = editor.timeline.tracks.filter { $0.kind == .caption }.compactMap(\.language)
        Menu {
            Section("Translate on this Mac") {
                ForEach(Self.languages, id: \.0) { code, name in
                    Button(installed.contains(code) ? name : "\(name) (download in System Settings)") {
                        Task { await editor.translateCaptions(to: code) }
                    }
                    .disabled(!installed.contains(code))
                }
            }
            if languages.count > 1 {
                Section("Burn in") {
                    ForEach(languages, id: \.self) { code in Button(code) { editor.showCaptions(language: code) } }
                }
            }
        } label: { Label("Captions", systemImage: "captions.bubble") }
        .help("Translate captions (exported as extra subtitle files) and choose the language shown on the video")
        .task {
            let source = editor.timeline.tracks.first { $0.kind == .caption }?.language ?? "en"
            let status = await CaptionTranslator.availability(from: Locale.Language(identifier: source),
                                                              to: Self.languages.map { Locale.Language(identifier: $0.0) })
            installed = Set(Self.languages.map(\.0).filter { status[Locale.Language(identifier: $0)] == .installed })
        }
    }
}
