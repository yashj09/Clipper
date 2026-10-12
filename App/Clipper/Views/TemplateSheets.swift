import ClipperAutomation
import ClipperCore
import SwiftUI

/// "Save as Template…" from the open timeline.
struct SaveTemplateSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var notes: [String]?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save as Template").font(.title2.bold())
            Text("Saves this timeline's layout, titles, branding, caption style and music settings so new clips can be drafted the same way. Per-clip zooms and reframing are re-generated for each new video.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Template name", text: $name).textFieldStyle(.roundedBorder)
            if let notes {
                Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                ForEach(notes, id: \.self) { Text("• " + $0).font(.caption) }
            }
            HStack {
                Spacer()
                Button(notes == nil ? "Cancel" : "Done") { dismiss() }.keyboardShortcut(.cancelAction)
                if notes == nil {
                    Button("Save") { notes = model.saveTemplateFromEditor(name: name) }
                        .keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(20).frame(width: 480)
        .onAppear { name = (model.editor?.project.name ?? "My") + " template" }
    }
}

/// Edit a template as JSON with live validation.
struct TemplateEditorSheet: View {
    @Bindable var model: AppModel
    let original: Template
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var issues: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(isNew ? "New template from “\(original.name)”" : "Edit “\(original.name)”").font(.title2.bold())
                Spacer()
                Text("Slots, rules, styles, music and export preset — see docs for every field").font(.caption).foregroundStyle(.secondary)
            }
            TextEditor(text: $text)
                .font(.system(.callout, design: .monospaced))
                .border(Color.gray.opacity(0.3))
                .onChange(of: text) { validate() }
            if issues.isEmpty {
                Label("Valid", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
            } else {
                ScrollView { VStack(alignment: .leading) { ForEach(issues, id: \.self) { Text("✗ " + $0).foregroundStyle(.red).font(.callout) } } }
                    .frame(maxHeight: 90)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    let (t, problems) = TemplateValidator.decode(Data(text.utf8))
                    guard let t, problems.isEmpty else { issues = problems; return }
                    model.saveTemplate(t)
                    dismiss()
                }
                .keyboardShortcut("s", modifiers: .command).disabled(!issues.isEmpty)
            }
        }
        .padding(20).frame(width: 820, height: 680)
        .onAppear {
            var t = original
            if isNew { t.id = original.id + "-copy"; t.name = original.name + " (copy)"; t.version = 1 }
            text = String(decoding: (try? ClipperJSON.encode(t)) ?? Data(), as: UTF8.self)
            validate()
        }
    }

    private func validate() { issues = TemplateValidator.decode(Data(text.utf8)).1 }
}

struct TemplateEditRequest: Identifiable {
    let template: Template
    let isNew: Bool
    var id: String { template.id + (isNew ? "+new" : "") }
}
