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
                Button("Import Media…") { model.chooseAndImport() }.keyboardShortcut("i", modifiers: [.command])
                Button("New Draft…") { model.draftSheet = [] }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Export…") { model.exportSheet = true }.keyboardShortcut("e", modifiers: [.command]).disabled(model.editor == nil)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo\(model.editor?.history.undoName.map { " " + $0 } ?? "")") { model.editor?.undo() }
                    .keyboardShortcut("z", modifiers: [.command]).disabled(model.editor?.history.canUndo != true)
                Button("Redo\(model.editor?.history.redoName.map { " " + $0 } ?? "")") { model.editor?.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(model.editor?.history.canRedo != true)
            }
            CommandMenu("Timeline") {
                Button("Split at Playhead") { model.editor?.bladeAtPlayhead() }.keyboardShortcut("k", modifiers: [.command])
                Button("Ripple Delete") { model.editor?.deleteSelection(ripple: true) }.keyboardShortcut(.delete, modifiers: [.shift])
                Button("Lock/Unlock Selection") { model.editor?.toggleLock() }.keyboardShortcut("l", modifiers: [.command])
                Divider()
                Button("Play/Pause") { model.editor?.togglePlay() }.keyboardShortcut("p", modifiers: [.command])
            }
        }
        Settings {
            SettingsView(model: model)
        }
    }
}

/// Flushes the editor's debounced autosave when the app quits.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationWillTerminate(_ notification: Notification) { model?.prepareForTermination() }
}
