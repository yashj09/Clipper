import ClipperCore
import SwiftUI

@main
struct ClipperApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Clipper") {
            MainView(model: model)
                .frame(minWidth: 1100, minHeight: 720)
                .onAppear { appDelegate.model = model }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                actionButton(.importMedia)
                actionButton(.newDraft)
                actionButton(.export)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo\(model.editor?.history.undoName.map { " " + $0 } ?? "")") { model.perform(.undo) }
                    .shortcut(.undo, in: model.settings.keyBindings).disabled(model.editor?.history.canUndo != true)
                Button("Redo\(model.editor?.history.redoName.map { " " + $0 } ?? "")") { model.perform(.redo) }
                    .shortcut(.redo, in: model.settings.keyBindings).disabled(model.editor?.history.canRedo != true)
            }
            CommandMenu("Playback") {
                ForEach(Self.menuActions(.playback), id: \.self) { actionButton($0) }
            }
            CommandMenu("Timeline") {
                ForEach(Self.menuActions(.editing), id: \.self) { actionButton($0) }
                Divider()
                ForEach(Self.menuActions(.marking), id: \.self) { actionButton($0) }
                Divider()
                ForEach(Self.menuActions(.adding), id: \.self) { actionButton($0) }
                Divider()
                ForEach(Self.menuActions(.view), id: \.self) { actionButton($0) }
            }
        }
        Settings {
            SettingsView(model: model)
        }
    }
}

extension ClipperApp {
    /// Menu items for an action group. Clipboard and selection actions stay off menus: the standard Edit menu owns
    /// ⌘C/⌘V/⌘A for text fields, and the key monitor handles them on the timeline.
    static func menuActions(_ group: EditorAction.Group) -> [EditorAction] {
        let offMenu: Set<EditorAction> = [.cut, .copy, .paste, .selectAll, .deselectAll, .undo, .redo]
        return EditorAction.allCases.filter { $0.group == group && !offMenu.contains($0) }
    }

    func actionButton(_ action: EditorAction) -> some View {
        Button(action.title) { model.perform(action) }
            .shortcut(action, in: model.settings.keyBindings)
            .disabled(!model.canPerform(action))
    }
}

/// Flushes the editor's debounced autosave when the app quits.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationWillTerminate(_ notification: Notification) { model?.prepareForTermination() }
}
