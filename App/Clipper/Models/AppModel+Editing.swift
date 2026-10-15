import AppKit
import ClipperAutomation
import ClipperCore
import Foundation

/// Keyboard actions and the editor's browser: actions that need more than the open editor (file commands, settings
/// toggles, adding library media) are handled here; the rest go to `EditorModel.run`.
@MainActor
extension AppModel {
    var isEditing: Bool {
        if case .project = section { return editor != nil }
        return false
    }

    /// Whether `action` applies right now; the key monitor lets the key through otherwise.
    func canPerform(_ action: EditorAction) -> Bool {
        switch action.group {
        case .file: action != .export || editor != nil
        default: isEditing
        }
    }

    /// Whether the main window is free for editor actions: no sheet over it and no text being typed. Menu shortcuts reach
    /// actions even when the key monitor stepped aside (text fields, sheets), so this is checked when they run.
    var isMainWindowIdle: Bool {
        guard let window = NSApp.keyWindow ?? keyMonitor.window else { return false }
        return window.attachedSheet == nil && window.sheetParent == nil && !(window.firstResponder is NSText)
    }

    func perform(_ action: EditorAction) {
        // Typing in a text field: ⌘Z / ⇧⌘Z belong to the text, other editor shortcuts do nothing.
        if action.group != .file, !isMainWindowIdle {
            if NSApp.keyWindow?.firstResponder is NSText, action == .undo || action == .redo {
                NSApp.sendAction(Selector((action == .undo ? "undo:" : "redo:")), to: nil, from: nil)
            }
            return
        }
        switch action {
        case .importMedia: chooseAndImport()
        case .newDraft: draftSheet = []
        case .export: if editor != nil, NSApp.keyWindow?.attachedSheet == nil { exportSheet = true }
        case .toggleSnapping:
            settings.editing.snapping.toggle()
            saveSettings()
        case .toggleRipple:
            settings.editing.rippleByDefault.toggle()
            saveSettings()
        case .connectToTimeline: addBrowserSelection(.connect)
        case .insertAtPlayhead: addBrowserSelection(.insert)
        case .appendToStoryline: addBrowserSelection(.append)
        case .overwriteAtPlayhead: addBrowserSelection(.overwrite)
        default: editor?.run(action)
        }
    }

    /// Q / W / E / D with whatever is selected in the editor's browser.
    func addBrowserSelection(_ mode: AddMode) {
        guard let editor, let item = editor.browserSelection else { return NSSound.beep() }
        Task {
            guard let addable = await addable(item, at: editor.playhead, in: editor) else { return NSSound.beep() }
            editor.add(addable, mode: mode)
        }
    }

    /// Drop from the browser (or the library grid) onto the timeline: onto a track at `time` — overwriting, or with ⌥
    /// inserting — or below the tracks, which connects it on a free or new track.
    func drop(_ item: BrowserItem, on track: TrackID?, at time: RationalTime, insert: Bool) {
        guard let editor else { return }
        Task {
            guard let addable = await addable(item, at: time, in: editor) else { return NSSound.beep() }
            editor.add(addable, mode: track == nil ? .connect : (insert ? .insert : .overwrite), track: track)
        }
    }

    /// Length and accepted track kinds of a dragged item, for the timeline's drop preview.
    func dropPreview(_ item: BrowserItem) -> (duration: RationalTime, kinds: [TrackKind])? {
        guard let editor else { return nil }
        let rate = editor.timeline.canvas.frameRate
        switch item {
        case .asset(let id):
            guard let asset = assets.first(where: { $0.id == id }) ?? editor.assets[id] else { return nil }
            return editor.clipItem(asset, at: .zero).map { ($0.item.range.duration, $0.kinds) }
        case .music(let id):
            guard let track = music.first(where: { $0.id == id }) else { return nil }
            return (RationalTime(seconds: track.duration).floorToFrame(rate), [.music, .audio])
        case .title:
            return (RationalTime(seconds: 3).roundedToFrame(rate), [.title, .overlay])
        }
    }

    /// Resolves a browser item to something addable. Music tracks become library assets on first use (with the same
    /// stable IDs drafts use), so the project still opens next time.
    private func addable(_ item: BrowserItem, at time: RationalTime, in editor: EditorModel) async -> AddableItem? {
        switch item {
        case .title(let style):
            return editor.textItem(style: style, at: time)
        case .asset(let id):
            guard let asset = editor.assets[id] ?? assets.first(where: { $0.id == id }) else { return nil }
            editor.assets[asset.id] = asset
            return editor.clipItem(asset, at: time)
        case .music(let id):
            guard let track = music.first(where: { $0.id == id }) else { return nil }
            let asset = DraftPipeline.musicAsset(track)
            if editor.assets[asset.id] == nil, let library {
                do { _ = try await library.importMedia([asset.url], mode: .reference) { _ in asset } } catch {
                    alert = "Couldn't add \(track.title): \(error)"
                    return nil
                }
            }
            editor.assets[asset.id] = asset
            var addable = editor.clipItem(asset, at: time)
            // Credit CC-BY music like drafts do.
            if let credit = track.license.attribution, !editor.timeline.attributions.contains(credit) {
                addable?.prerequisites.append(AddAttribution(credit))
            }
            return addable
        }
    }
}

/// Adds a licence credit to the timeline (e.g. CC-BY music added by hand).
struct AddAttribution: EditCommand {
    var credit: String
    init(_ credit: String) { self.credit = credit }
    var name: String { "Add Credit" }
    func apply(to timeline: Timeline, context: EditContext) throws -> Timeline {
        var t = timeline
        if !t.attributions.contains(credit) { t.attributions.append(credit) }
        return t
    }
}

// MARK: Re-draft

@MainActor
extension AppModel {
    /// A request re-running the open timeline's draft from its recorded clips, with a (possibly different) template and
    /// options. Clips in a slot the new template doesn't have are left out. Nil when the timeline wasn't drafted.
    func redraftRequest(template: Template, seed: UInt64, title: String, captions: Bool, music: Bool) -> DraftRequest? {
        guard let editor, let record = Redraft.record(of: editor.timeline) else { return nil }
        let oldPrimary = editor.timeline.provenance.flatMap { p in templates.first { $0.id == p.template } }?.primarySlot?.id
        let newSlots = Set(template.slots.map(\.id))
        var request = DraftRequest(template: template, primary: [], title: title, captions: captions, music: music,
                                   maxDuration: record.maxDuration, seed: seed)
        for clip in record.clips {
            if clip.slot == nil || clip.slot == oldPrimary || clip.slot == template.primarySlot?.id {
                request.primary.append(clip.asset)
            } else if let slot = clip.slot, newSlots.contains(slot) {
                request.slots[slot, default: []].append(clip.asset)
            }
            if clip.inPoint != nil || clip.outPoint != nil {
                request.trims[clip.asset] = (clip.inPoint ?? 0)...(clip.outPoint ?? .greatestFiniteMagnitude)
            }
        }
        return request
    }

    /// Re-drafts the open timeline, keeping the user's locked and added items (one undo step).
    func redraft(_ request: DraftRequest) async {
        guard let editor, let result = await makeDraft(request) else { return }
        // The new draft may use assets the editor hasn't seen (newly picked music): register them before rendering.
        for asset in result.addedAssets { editor.assets[asset.id] = asset }
        for (id, asset) in allAssets where editor.assets[id] == nil { editor.assets[id] = asset }
        let merged = Redraft.merge(editor.timeline, into: result.timeline, context: editor.context)
        editor.perform(ReplaceTimeline(merged.timeline, name: "Re-draft"))
        let note = "Kept \(merged.kept) of your item\(merged.kept == 1 ? "" : "s") · ⌘Z goes back"
        activity = Activity(title: "Re-drafted with \(request.template.name)", detail: note, progress: 1)
        if !result.report.warnings.isEmpty { alert = "Re-drafted.\n\n" + result.report.warnings.map { "⚠️ " + $0 }.joined(separator: "\n") }
        try? await Task.sleep(for: .seconds(3))
        if activity?.detail == note { activity = nil }
    }
}
