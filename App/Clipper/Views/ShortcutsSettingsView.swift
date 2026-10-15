import AppKit
import ClipperCore
import SwiftUI

/// Settings ▸ Shortcuts: every editor action with its shortcuts. Click + and press keys to add one (a shortcut another
/// action had moves here, with a note), × removes one, and Reset goes back to the factory shortcuts.
struct ShortcutsSettingsView: View {
    @Bindable var model: AppModel
    @State private var search = ""
    @State private var recording: EditorAction?
    @State private var notice: String?

    private var bindings: KeyBindings { model.settings.keyBindings }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search actions or keys", text: $search).textFieldStyle(.roundedBorder)
                Button("Reset All") { model.settings.keyBindings.resetAll(); notice = nil }
                    .disabled(bindings == KeyBindings())
            }
            .padding([.horizontal, .top], 16).padding(.bottom, 8)
            if let notice {
                Text(notice).font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
            }
            Form {
                ForEach(EditorAction.Group.allCases, id: \.self) { group in
                    let actions = EditorAction.allCases.filter { $0.group == group && matches($0) }
                    if !actions.isEmpty {
                        Section(group.rawValue) {
                            ForEach(actions) { row($0) }
                        }
                    }
                }
                Section {
                    Text("Single keys (B, J, K, L…) work anywhere in the editor window except while typing in a text field. Shortcuts with ⌘ or ⌃ also appear in the menus.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
    }

    private func row(_ action: EditorAction) -> some View {
        let shortcuts = bindings.shortcuts(for: action)
        let conflicts = bindings.conflicts
        return LabeledContent {
            HStack(spacing: 4) {
                ForEach(shortcuts, id: \.self) { s in
                    HStack(spacing: 2) {
                        Text(s.display).font(.system(.callout, design: .rounded).monospaced())
                        Button { model.settings.keyBindings.remove(s, from: action) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove \(s.display)")
                    }
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(conflicts[s] != nil ? Color.orange.opacity(0.3) : Color.secondary.opacity(0.15)))
                    .help(conflicts[s].map { "Also bound to " + $0.filter { $0 != action }.map(\.title).joined(separator: ", ") } ?? "")
                }
                if recording == action {
                    ShortcutRecorder { captured in
                        recording = nil
                        guard let captured else { return }
                        let displaced = model.settings.keyBindings.assign(captured, to: action)
                        notice = displaced.isEmpty ? nil
                            : "\(captured.display) was removed from “\(displaced.map(\.title).joined(separator: "”, “"))”."
                    }
                    .frame(width: 130, height: 22)
                } else {
                    Button { recording = action } label: { Image(systemName: "plus.circle") }
                        .buttonStyle(.borderless).help("Add a shortcut")
                }
                if bindings.isCustomized(action) {
                    Button("Reset") { model.settings.keyBindings.reset(action) }.controlSize(.small)
                }
            }
        } label: {
            Text(action.title)
        }
    }

    private func matches(_ a: EditorAction) -> Bool {
        search.isEmpty || a.title.localizedCaseInsensitiveContains(search)
            || bindings.shortcuts(for: a).contains { $0.display.localizedCaseInsensitiveContains(search) }
    }
}

/// Captures the next key press (⌘ combos included) as a shortcut. Esc or clicking away cancels.
struct ShortcutRecorder: NSViewRepresentable {
    var onCapture: (KeyShortcut?) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let v = RecorderView()
        v.onCapture = onCapture
        return v
    }

    func updateNSView(_ v: RecorderView, context: Context) { v.onCapture = onCapture }

    final class RecorderView: NSView {
        var onCapture: ((KeyShortcut?) -> Void)?
        private var done = false

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill(); path.fill()
            NSColor.controlAccentColor.setStroke(); path.stroke()
            let text = "Type a shortcut…" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
            let size = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
        }

        private func finish(_ s: KeyShortcut?) {
            guard !done else { return }
            done = true
            onCapture?(s)
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53, event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty { return finish(nil) }
            if let s = KeyShortcut(event: event) { finish(s) }
        }

        /// ⌘ combinations arrive here before the menus would take them.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self, let s = KeyShortcut(event: event) else { return false }
            finish(s)
            return true
        }

        override func resignFirstResponder() -> Bool {
            DispatchQueue.main.async { [weak self] in self?.finish(nil) }
            return true
        }
    }
}
