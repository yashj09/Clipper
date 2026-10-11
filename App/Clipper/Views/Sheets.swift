import AppKit
import ClipperAutomation
import ClipperCore
import ClipperEngine
import SwiftUI

/// Choose a template, assign clips to its slots, set a title and options, then draft.
struct DraftSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var templateID: String
    @State private var assignment: [String: [AssetID]] = [:]
    @State private var title = ""
    @State private var captions = true
    @State private var music = true
    @State private var maxDuration: Double = 0
    @State private var seed: UInt64 = 1

    init(model: AppModel, initial: [AssetID]) {
        self.model = model
        let id = model.settings.automation.defaultTemplate
        _templateID = State(initialValue: model.templates.contains { $0.id == id } ? id : (model.templates.first?.id ?? "talking-head"))
        let primary = model.templates.first { $0.id == id }?.primarySlot?.id ?? "speaker"
        _assignment = State(initialValue: [primary: initial])
        _captions = State(initialValue: model.settings.automation.captions)
        _music = State(initialValue: model.settings.automation.music)
    }

    var template: Template { model.templates.first { $0.id == templateID } ?? BuiltIns.talkingHead }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New automatic draft").font(.title2.bold())
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(model.templates) { t in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(t.name).font(.headline)
                            Text(t.summary).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                        .padding(10).frame(width: 200, height: 96, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(t.id == templateID ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.12)))
                        .onTapGesture { select(t) }
                    }
                }
            }
            ForEach(template.slots, id: \.id) { slot in
                SlotEditor(model: model, slot: slot, clips: Binding(get: { assignment[slot.id] ?? [] }, set: { assignment[slot.id] = $0 }))
            }
            Form {
                TextField("Title (shown at the start)", text: $title)
                Toggle("Captions", isOn: $captions).disabled(template.rules.captions == nil)
                Toggle("Music" + (model.music.isEmpty ? " (library is empty — add music first)" : ""), isOn: $music)
                LabeledContent("Max duration") {
                    HStack {
                        Slider(value: $maxDuration, in: 0...180, step: 5)
                        Text(maxDuration == 0 ? "Template (\(Int(template.rules.maxDuration ?? 0))s)" : "\(Int(maxDuration))s").frame(width: 110)
                    }
                }
                Stepper("Variation \(seed)", value: $seed, in: 1...999).help("Different variations pick different music and other choices")
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create Draft") {
                    let primary = template.primarySlot?.id ?? ""
                    let request = DraftRequest(template: template, primary: assignment[primary] ?? [],
                                               slots: assignment.filter { $0.key != primary && !$0.value.isEmpty },
                                               title: title, captions: captions, music: music,
                                               maxDuration: maxDuration == 0 ? nil : maxDuration, seed: seed)
                    dismiss()
                    Task { await model.createDraft(request) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled((assignment[template.primarySlot?.id ?? ""] ?? []).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 720, height: 640)
    }

    private func select(_ t: Template) {
        // Carry the clips over to the new template's primary slot.
        let clips = assignment[template.primarySlot?.id ?? ""] ?? []
        templateID = t.id
        assignment = [t.primarySlot?.id ?? "": clips]
    }
}

private struct SlotEditor: View {
    @Bindable var model: AppModel
    let slot: Slot
    @Binding var clips: [AssetID]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(slot.name).font(.headline)
                Text(slot.role == .primary ? "main storyline" : slot.optional ? "optional" : "").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu("Add clip") {
                    ForEach(model.assets.filter { $0.info.kind != .audio && !clips.contains($0.id) }) { a in
                        Button(a.name) { clips.append(a.id) }
                    }
                }
                .fixedSize()
            }
            ScrollView(.horizontal) {
                HStack {
                    ForEach(Array(clips.enumerated()), id: \.element) { i, id in
                        HStack(spacing: 4) {
                            Text("\(i + 1). " + (model.assets.first { $0.id == id }?.name ?? "?")).lineLimit(1)
                            Button { clips.remove(at: i) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color.gray.opacity(0.18)))
                    }
                    if clips.isEmpty { Text("Drop clips here or use “Add clip”").foregroundStyle(.secondary).font(.callout) }
                }
            }
            .frame(height: 30)
            .dropDestination(for: String.self) { items, _ in
                let ids = items.compactMap(UUID.init(uuidString:)).filter { !clips.contains($0) }
                clips += ids
                return !ids.isEmpty
            }
        }
    }
}

struct ExportSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var presetID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export").font(.title2.bold())
            Picker("Preset", selection: $presetID) {
                ForEach(ExportPreset.builtIn) { Text($0.name).tag($0.id) }
            }
            if let p = ExportPreset.named(presetID), let canvas = model.editor?.timeline.canvas,
               let w = p.width, let h = p.height, abs(Double(w) / Double(h) - canvas.aspect) > 0.01 {
                Text("⚠️ This preset's aspect ratio differs from the timeline (\(canvas.width)×\(canvas.height)); slots will be re-laid out.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let credits = model.editor?.timeline.attributions, !credits.isEmpty {
                Text("Music credits to include in your post:").font(.caption.bold())
                Text(credits.joined(separator: "\n")).font(.caption).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…") {
                    guard let preset = ExportPreset.named(presetID), let editor = model.editor else { return }
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = "\(editor.project.name).\(preset.container.fileExtension)"
                    panel.directoryURL = (try? model.library?.exportFolder())
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    dismiss()
                    Task { await model.export(preset: preset, to: url) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            let t = model.editor?.timeline
            let byTemplate = t?.provenance.flatMap { p in model.templates.first { $0.id == p.template }?.exportPreset }
            presetID = byTemplate ?? model.settings.export.defaultPreset
        }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            Form {
                Toggle("Ripple edits by default", isOn: $model.settings.editing.rippleByDefault)
                Toggle("Snapping", isOn: $model.settings.editing.snapping)
                Picker("Preview quality", selection: $model.settings.editing.previewScale) {
                    Text("Full").tag(1.0); Text("Half").tag(0.5); Text("Quarter").tag(0.25)
                }
                Toggle("Use proxies when available", isOn: $model.settings.editing.useProxies)
            }
            .tabItem { Label("Editing", systemImage: "timeline.selection") }
            Form {
                Picker("Default template", selection: $model.settings.automation.defaultTemplate) {
                    ForEach(model.templates) { Text($0.name).tag($0.id) }
                }
                Toggle("Captions by default", isOn: $model.settings.automation.captions)
                Toggle("Music by default", isOn: $model.settings.automation.music)
                Toggle("Face tracking (reframing)", isOn: $model.settings.automation.faceTracking)
                TextField("Speech language", text: $model.settings.automation.transcriptionLocale)
            }
            .tabItem { Label("Automation", systemImage: "wand.and.stars") }
            Form {
                Picker("Default preset", selection: $model.settings.export.defaultPreset) {
                    ForEach(ExportPreset.builtIn) { Text($0.name).tag($0.id) }
                }
                LabeledContent("Export folder") {
                    Text(model.settings.export.outputFolder?.path ?? "Library ▸ Exports").foregroundStyle(.secondary)
                    Button("Choose…") {
                        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                        if p.runModal() == .OK { model.settings.export.outputFolder = p.url }
                    }
                }
                Toggle("Write SRT/VTT caption files", isOn: $model.settings.export.writeSidecars)
            }
            .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 320)
        .onChange(of: model.settings) { model.saveSettings() }
    }
}
