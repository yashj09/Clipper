import ClipperAutomation
import ClipperCore
import SwiftUI

/// Re-run the automatic draft for the open timeline — another template, variation or options — keeping what the user
/// locked or added.
struct RedraftSheet: View {
    @Bindable var model: AppModel
    @Bindable var editor: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var templateID = ""
    @State private var title = ""
    @State private var captions = true
    @State private var music = true
    @State private var seed: UInt64 = 1

    private var template: Template? { model.templates.first { $0.id == templateID } }

    /// What survives: items the user added or locked, and everything on locked tracks.
    private var keptCount: Int {
        editor.timeline.tracks.reduce(0) { n, t in n + (t.locked ? t.items.count : t.items.filter { $0.origin == .user || $0.locked }.count) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Re-draft").font(.title2.bold())
            Text("Runs the automatic draft again on the same clips. Items you added or locked (and locked tracks) stay where they are; everything else is replaced. \(keptCount) item\(keptCount == 1 ? "" : "s") will be kept. ⌘Z undoes the re-draft.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                Picker("Template", selection: $templateID) {
                    ForEach(model.templates) { Text($0.name).tag($0.id) }
                }
                TextField("Title", text: $title)
                Toggle("Captions", isOn: $captions).disabled(template?.rules.captions == nil)
                Toggle("Music" + (model.music.isEmpty ? " (library is empty)" : ""), isOn: $music)
                Stepper("Variation \(seed)", value: $seed, in: 1...999).help("Different variations pick different music and other choices")
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Re-draft") {
                    guard let template, let request = model.redraftRequest(template: template, seed: seed, title: title,
                                                                            captions: captions, music: music) else { return }
                    dismiss()
                    Task { await model.redraft(request) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(template == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            let tl = editor.timeline
            let record = Redraft.record(of: tl)
            templateID = tl.provenance?.template ?? model.settings.automation.defaultTemplate
            title = record?.title ?? ""
            captions = record?.captions ?? tl.tracks.contains { $0.kind == .caption }
            music = record?.music ?? tl.tracks.contains { $0.kind == .music }
            seed = tl.provenance?.seed ?? 1
        }
    }
}
