#if DEBUG
import AppKit
import AVFoundation
import ClipperCore
import Foundation

/// Debug builds only: drives the app from a script so editor features can be smoke-tested without clicking.
/// `CLIPPER_LIBRARY=/path/Test.clipperlib` opens another library (keep tests away from real projects) and
/// `CLIPPER_DEBUG_SCRIPT=/path/script.txt` runs one command per line once the window is up:
///
///     open <project name>            key <shortcut spec>        (posted as a real key event, so the key monitor runs)
///     seek <seconds>                 action <EditorAction>      browse asset|music|title <name>
///     drop asset|music|title <name> <seconds> [<track kind>] [insert]
///     wait <seconds>                 dump <file>                (timeline summary as text)
///     settings                       quit
@MainActor
enum DebugScript {
    static func runIfRequested(_ model: AppModel) {
        guard let path = ProcessInfo.processInfo.environment["CLIPPER_DEBUG_SCRIPT"],
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            // Never activate: the app would take keyboard focus from whatever the person at the Mac is doing.
            for w in NSApp.windows where w.isMiniaturized { w.deminiaturize(nil) }
            try? await Task.sleep(for: .seconds(0.8))
            for line in lines {
                log("> \(line)")
                await run(line, model)
            }
        }
    }

    static func log(_ s: String) {
        FileHandle.standardError.write(Data(("[script] " + s + "\n").utf8))
    }

    private static func run(_ line: String, _ model: AppModel) async {
        let words = line.split(separator: " ").map(String.init)
        let rest = words.dropFirst().joined(separator: " ")
        switch words.first {
        case "open":
            guard let p = model.projects.first(where: { $0.name == rest }) else { return log("no project \(rest)") }
            model.open(p.id)
        case "seek":
            model.editor?.seek(to: RationalTime(seconds: Double(rest) ?? 0))
        case "action":
            guard let a = EditorAction(rawValue: rest) else { return log("unknown action \(rest)") }
            model.perform(a)
        case "key":
            guard let s = KeyShortcut(spec: rest), let event = keyEvent(s) else { return log("bad key \(rest)") }
            NSApp.postEvent(event, atStart: false)
            try? await Task.sleep(for: .milliseconds(150))
        case "browse":
            model.editor?.browserSelection = browserItem(words.dropFirst().map { $0 }, model)
        case "drop":
            // drop <kind> <name…> <seconds> [<track kind>] [insert]
            var args = Array(words.dropFirst())
            let insert = args.last == "insert"
            if insert { args.removeLast() }
            var trackKind: TrackKind?
            if let k = args.last.flatMap(TrackKind.init(rawValue:)) { trackKind = k; args.removeLast() }
            guard let secs = args.last.flatMap(Double.init) else { return log("drop needs a time") }
            args.removeLast()
            guard let item = browserItem(args, model), let editor = model.editor else { return log("nothing to drop") }
            let track = trackKind.flatMap { k in editor.timeline.tracks.first { $0.kind == k }?.id }
            model.drop(item, on: track, at: RationalTime(seconds: secs).roundedToFrame(editor.timeline.canvas.frameRate), insert: insert)
            try? await Task.sleep(for: .milliseconds(300))
        case "wait":
            try? await Task.sleep(for: .seconds(Double(rest) ?? 1))
        case "dump":
            guard let editor = model.editor else { return }
            try? summary(editor).write(toFile: rest, atomically: true, encoding: .utf8)
        case "redraft":
            // redraft <template id> <seed>
            let parts = rest.split(separator: " ").map(String.init)
            guard parts.count == 2, let t = model.templates.first(where: { $0.id == parts[0] }), let seed = UInt64(parts[1]),
                  let r = model.redraftRequest(template: t, seed: seed, title: "Re-drafted", captions: true, music: false)
            else { return log("bad redraft") }
            await model.redraft(r)
            if let a = model.alert { log("alert: \(a)"); model.alert = nil }
        case "select":
            // select <track kind> <item index>
            let parts = rest.split(separator: " ").map(String.init)
            guard parts.count == 2, let kind = TrackKind(rawValue: parts[0]), let i = Int(parts[1]), let editor = model.editor,
                  let item = editor.timeline.tracks.first(where: { $0.kind == kind })?.items[safe: i] else { return log("bad select") }
            editor.selection = [item.id]
        case "keyframe":
            // keyframe opacity <item seconds> <value> — on the selected item, the same edit the inspector's ◆ makes
            let parts = rest.split(separator: " ").map(String.init)
            guard parts.count == 3, parts[0] == "opacity", let t = Double(parts[1]), let v = Double(parts[2]),
                  let editor = model.editor, let id = editor.selection.first else { return log("bad keyframe") }
            let half = RationalTime(seconds: editor.timeline.canvas.frameRate.frameDuration.seconds / 2)
            editor.perform(ModifyItem(id, name: "Add Keyframe") { $0.opacity = $0.opacity.setting(v, at: RationalTime(seconds: t), tolerance: half) })
        case "canvas":
            // canvas <width> <height>
            let parts = rest.split(separator: " ").compactMap { Int($0) }
            guard parts.count == 2, let editor = model.editor else { return log("bad canvas") }
            editor.perform(ChangeCanvas(Canvas(width: parts[0], height: parts[1], frameRate: editor.timeline.canvas.frameRate)))
            editor.zoomRequest = .fit(UUID())
        case "look":
            // look <name> — on the selected items
            guard let editor = model.editor, let look = ColorAdjust.looks.first(where: { $0.name == rest }) else { return log("bad look") }
            let ids = editor.selection
            editor.perform(ModifyTimeline(name: "Look") { t in
                for ti in t.tracks.indices { for ii in t.tracks[ti].items.indices where ids.contains(t.tracks[ti].items[ii].id) { t.tracks[ti].items[ii].color = look.adjust } }
            })
        case "transition":
            // transition <crossDissolve|dipToBlack|dipToWhite> <seconds> — on the selected items
            let parts = rest.split(separator: " ").map(String.init)
            guard parts.count == 2, let kind = ClipperCore.Transition.Kind(rawValue: parts[0]), let d = Double(parts[1]), let editor = model.editor else { return log("bad transition") }
            editor.perform(Batch(editor.selectedItems.map { ModifyItem($0.id, name: "") { $0.transition = ClipperCore.Transition(kind, duration: RationalTime(seconds: d)) } }, name: "Transition"))
        case "drag":
            // drag <fromX> <fromY> <toX> <toY> [option|shift] — fractions of the picture in the viewer; real mouse events
            let parts = rest.split(separator: " ").map(String.init)
            let n = parts.prefix(4).compactMap(Double.init)
            guard n.count == 4, let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let picture = Self.playerView(in: window.contentView!) else { return log("bad drag / no viewer") }
            let flags: NSEvent.ModifierFlags = parts.contains("option") ? .option : (parts.contains("shift") ? .shift : [])
            let r = picture.convert(picture.bounds, to: nil)   // window coordinates (y up)
            func point(_ fx: Double, _ fy: Double) -> CGPoint { CGPoint(x: r.minX + r.width * fx, y: r.maxY - r.height * fy) }
            func post(_ type: NSEvent.EventType, _ p: CGPoint) {
                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.postEvent(e, atStart: false)
                }
            }
            post(.leftMouseDown, point(n[0], n[1]))
            try? await Task.sleep(for: .milliseconds(80))
            for i in 1...10 {
                let u = Double(i) / 10
                post(.leftMouseDragged, point(n[0] + (n[2] - n[0]) * u, n[1] + (n[3] - n[1]) * u))
                try? await Task.sleep(for: .milliseconds(30))
            }
            post(.leftMouseUp, point(n[2], n[3]))
            try? await Task.sleep(for: .milliseconds(300))
        case "bind":
            // bind <action> <shortcut spec>: the same path as recording a shortcut in Settings.
            let parts = rest.split(separator: " ").map(String.init)
            guard parts.count == 2, let a = EditorAction(rawValue: parts[0]), let k = KeyShortcut(spec: parts[1]) else { return log("bad bind") }
            let displaced = model.settings.keyBindings.assign(k, to: a)
            model.saveSettings()
            log("bound \(k.display) to \(a.rawValue); removed from \(displaced.map(\.rawValue))")
        case "default":
            // default <key> <value>: e.g. preselect a Settings tab before opening Settings.
            let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
            if parts.count == 2 { UserDefaults.standard.set(parts[1], forKey: parts[0]) }
        case "settings":
            // SwiftUI apps open Settings through the app menu's item, not a responder-chain selector.
            if let menu = NSApp.mainMenu?.items.first?.submenu,
               let i = menu.items.firstIndex(where: { $0.title.hasPrefix("Settings") }) { menu.performActionForItem(at: i) }
        case "quit":
            NSApp.terminate(nil)
        default:
            log("unknown command: \(line)")
        }
        if let e = model.editor?.lastError { log("editor error: \(e)"); model.editor?.lastError = nil }
    }

    /// The view hosting the preview's AVPlayerLayer (the picture).
    static func playerView(in view: NSView) -> NSView? {
        if view.layer is AVPlayerLayer { return view }
        for sub in view.subviews { if let v = playerView(in: sub) { return v } }
        return nil
    }

    private static func browserItem(_ args: [String], _ model: AppModel) -> BrowserItem? {
        guard let kind = args.first else { return nil }
        let name = args.dropFirst().joined(separator: " ")
        switch kind {
        case "asset": return model.assets.first { $0.name == name }.map { .asset($0.id) }
        case "music": return model.music.first { $0.title == name }.map { .music($0.id) }
        case "title": return .title(name)
        default: return nil
        }
    }

    static func summary(_ editor: EditorModel) -> String {
        let tl = editor.timeline
        var out = "duration \(String(format: "%.3f", tl.duration.seconds)) playhead \(String(format: "%.3f", editor.playhead.seconds))"
        out += " in \(editor.inPoint.map { String(format: "%.3f", $0.seconds) } ?? "-") out \(editor.outPoint.map { String(format: "%.3f", $0.seconds) } ?? "-")"
        out += " selected \(editor.selectedItems.map(\.name).joined(separator: ","))(\(editor.selection.count)) undo \(editor.history.undoName ?? "-") playing \(editor.player.isPlaying)\n"
        for t in tl.tracks {
            out += "\(t.kind.rawValue) \(t.name):"
            for i in t.items {
                var label = i.name
                if case .text(let x) = i.content { label = "“\(x.text)”" }
                if case .caption(let c) = i.content { label = "[\(c.text)]" }
                if let m = i.content.mediaRef, m.speed != 1 { label += "@\(m.speed)x" }
                out += String(format: " %@ %.3f-%.3f", label, i.start.seconds, i.end.seconds)
            }
            out += "\n"
        }
        return out
    }

    /// US-layout key codes for the characters scripts use.
    private static let codes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
        "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, ";": 41,
        "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "space": 49, "delete": 51, "escape": 53, "return": 36,
        "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "forwardDelete": 117,
    ]

    private static func keyEvent(_ s: KeyShortcut) -> NSEvent? {
        guard let code = codes[s.key] else { return nil }
        guard let window = NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) else { log("no visible window"); return nil }
        var flags: NSEvent.ModifierFlags = []
        if s.modifiers.contains(.command) { flags.insert(.command) }
        if s.modifiers.contains(.shift) { flags.insert(.shift) }
        if s.modifiers.contains(.option) { flags.insert(.option) }
        if s.modifiers.contains(.control) { flags.insert(.control) }
        let chars = s.key.count == 1 ? s.key : (s.key == "space" ? " " : "")
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: window.windowNumber, context: nil, characters: chars,
                                charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
    }
}
extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
#endif
