import Foundation

/// A key plus modifiers, stored as readable text such as `"cmd+shift+k"`, `"space"` or `"option+["`.
/// `key` is the unshifted character (lowercase letter, digit or punctuation) or a named key (`space`, `left`, `delete`…),
/// so Shift is always an explicit modifier and ⇧, matches the same physical key as ,.
public struct KeyShortcut: Hashable, Sendable, CustomStringConvertible {
    /// Declared in the order macOS displays them: ⌃⌥⇧⌘.
    public enum Modifier: String, Sendable, CaseIterable, Comparable {
        case control, option, shift, command

        public var symbol: String {
            switch self { case .control: "⌃"; case .option: "⌥"; case .shift: "⇧"; case .command: "⌘" }
        }
        public static func < (a: Modifier, b: Modifier) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }
        static let aliases: [String: Modifier] = ["cmd": .command, "command": .command, "ctrl": .control, "control": .control,
                                                  "opt": .option, "option": .option, "alt": .option, "shift": .shift]
    }

    /// Keys without a printable character, by their stored name.
    public static let namedKeys: [String: String] = [
        "space": "Space", "return": "↩", "enter": "⌤", "tab": "⇥", "escape": "⎋", "delete": "⌫", "forwardDelete": "⌦",
        "left": "←", "right": "→", "up": "↑", "down": "↓", "home": "↖", "end": "↘", "pageUp": "⇞", "pageDown": "⇟",
        "f1": "F1", "f2": "F2", "f3": "F3", "f4": "F4", "f5": "F5", "f6": "F6",
        "f7": "F7", "f8": "F8", "f9": "F9", "f10": "F10", "f11": "F11", "f12": "F12",
    ]

    public var key: String
    public var modifiers: Set<Modifier>

    public init(_ key: String, _ modifiers: Set<Modifier> = []) {
        self.key = Self.namedKeys[key] != nil ? key : key.lowercased()
        self.modifiers = modifiers
    }

    /// Parses `"cmd+shift+k"`; nil for an unknown modifier, an empty key or a multi-character unnamed key.
    public init?(spec: String) {
        var parts = spec.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // "cmd++" is ⌘ and the + key.
        if spec.hasSuffix("++") { parts.removeLast(2); parts.append("+") }
        guard let last = parts.popLast(), !last.isEmpty else { return nil }
        var mods = Set<Modifier>()
        for p in parts {
            guard let m = Modifier.aliases[p.lowercased()] else { return nil }
            mods.insert(m)
        }
        let named = Self.namedKeys.keys.first { $0.lowercased() == last.lowercased() }
        guard named != nil || last.count == 1 else { return nil }
        self.init(named ?? last, mods)
    }

    /// Stored form, modifiers in display order: `"ctrl+option+shift+cmd+k"`.
    public var spec: String {
        let names: [Modifier: String] = [.control: "ctrl", .option: "option", .shift: "shift", .command: "cmd"]
        return (modifiers.sorted().map { names[$0]! } + [key]).joined(separator: "+")
    }

    /// As shown in menus and Settings: `"⇧⌘K"`, `"Space"`, `"⌥["`.
    public var display: String {
        modifiers.sorted().map(\.symbol).joined() + (Self.namedKeys[key] ?? key.uppercased())
    }

    public var description: String { display }

    /// Whether the shortcut includes ⌘ or ⌃. Only these may go on menu items: a plain key (or ⌥/⇧ + key) there would
    /// fire as a key equivalent before a focused text field gets to type it.
    public var isMenuSafe: Bool { modifiers.contains(.command) || modifiers.contains(.control) }
}

extension KeyShortcut: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let v = KeyShortcut(spec: s) else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad shortcut \(s)") }
        self = v
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(spec)
    }
}

/// Everything the editor can do from the keyboard. The raw value is the stable ID stored in settings.
public enum EditorAction: String, Sendable, CaseIterable, Identifiable {
    // Playback
    case playPause, shuttleBackward, pause, shuttleForward
    case previousFrame, nextFrame, back10Frames, forward10Frames
    case previousEdit, nextEdit, goToStart, goToEnd
    // Marking
    case setIn, setOut, clearInOut, selectClipRange
    // Editing
    case blade, bladeAllTracks, delete, rippleDelete, deleteLeavingGap
    case trimStartToPlayhead, trimEndToPlayhead, nudgeLeft, nudgeRight
    case selectClipAtPlayhead, selectAll, deselectAll
    case cut, copy, paste, duplicate
    case toggleLock, undo, redo
    // Adding
    case addText, connectToTimeline, insertAtPlayhead, appendToStoryline, overwriteAtPlayhead
    // View
    case zoomIn, zoomOut, zoomToFit, toggleSnapping, toggleRipple
    // File
    case importMedia, newDraft, export

    public var id: String { rawValue }

    public enum Group: String, Sendable, CaseIterable {
        case playback = "Playback", marking = "Marking", editing = "Editing", adding = "Adding to the Timeline"
        case view = "View", file = "File"
    }

    public var group: Group {
        switch self {
        case .playPause, .shuttleBackward, .pause, .shuttleForward, .previousFrame, .nextFrame, .back10Frames,
             .forward10Frames, .previousEdit, .nextEdit, .goToStart, .goToEnd: .playback
        case .setIn, .setOut, .clearInOut, .selectClipRange: .marking
        case .blade, .bladeAllTracks, .delete, .rippleDelete, .deleteLeavingGap, .trimStartToPlayhead, .trimEndToPlayhead,
             .nudgeLeft, .nudgeRight, .selectClipAtPlayhead, .selectAll, .deselectAll, .cut, .copy, .paste, .duplicate,
             .toggleLock, .undo, .redo: .editing
        case .addText, .connectToTimeline, .insertAtPlayhead, .appendToStoryline, .overwriteAtPlayhead: .adding
        case .zoomIn, .zoomOut, .zoomToFit, .toggleSnapping, .toggleRipple: .view
        case .importMedia, .newDraft, .export: .file
        }
    }

    public var title: String {
        switch self {
        case .playPause: "Play / Pause"
        case .shuttleBackward: "Play Backward (press again to go faster)"
        case .pause: "Pause"
        case .shuttleForward: "Play Forward (press again to go faster)"
        case .previousFrame: "Previous Frame"
        case .nextFrame: "Next Frame"
        case .back10Frames: "Back 10 Frames"
        case .forward10Frames: "Forward 10 Frames"
        case .previousEdit: "Go to Previous Edit"
        case .nextEdit: "Go to Next Edit"
        case .goToStart: "Go to Start"
        case .goToEnd: "Go to End"
        case .setIn: "Set In Point"
        case .setOut: "Set Out Point"
        case .clearInOut: "Clear In and Out"
        case .selectClipRange: "Mark the Clip Under the Playhead"
        case .blade: "Split at Playhead"
        case .bladeAllTracks: "Split All Tracks at Playhead"
        case .delete: "Delete (follows the Ripple setting)"
        case .rippleDelete: "Ripple Delete (close the gap)"
        case .deleteLeavingGap: "Delete Leaving a Gap"
        case .trimStartToPlayhead: "Trim Start to Playhead"
        case .trimEndToPlayhead: "Trim End to Playhead"
        case .nudgeLeft: "Nudge Left One Frame"
        case .nudgeRight: "Nudge Right One Frame"
        case .selectClipAtPlayhead: "Select Clip at Playhead"
        case .selectAll: "Select All"
        case .deselectAll: "Deselect All"
        case .cut: "Cut"
        case .copy: "Copy"
        case .paste: "Paste at Playhead"
        case .duplicate: "Duplicate"
        case .toggleLock: "Lock / Unlock Selection"
        case .undo: "Undo"
        case .redo: "Redo"
        case .addText: "Add Text at Playhead"
        case .connectToTimeline: "Connect Browser Clip at Playhead"
        case .insertAtPlayhead: "Insert Browser Clip at Playhead"
        case .appendToStoryline: "Append Browser Clip to Storyline"
        case .overwriteAtPlayhead: "Overwrite with Browser Clip at Playhead"
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        case .zoomToFit: "Zoom to Fit"
        case .toggleSnapping: "Snapping On / Off"
        case .toggleRipple: "Ripple Edits On / Off"
        case .importMedia: "Import Media…"
        case .newDraft: "New Draft…"
        case .export: "Export…"
        }
    }

    /// Factory shortcuts, modelled on Final Cut Pro and Premiere where they agree.
    public var defaultShortcuts: [KeyShortcut] {
        func k(_ key: String, _ m: KeyShortcut.Modifier...) -> KeyShortcut { KeyShortcut(key, Set(m)) }
        switch self {
        case .playPause: return [k("space")]
        case .shuttleBackward: return [k("j")]
        case .pause: return [k("k")]
        case .shuttleForward: return [k("l")]
        case .previousFrame: return [k("left")]
        case .nextFrame: return [k("right")]
        case .back10Frames: return [k("left", .shift)]
        case .forward10Frames: return [k("right", .shift)]
        case .previousEdit: return [k("up")]
        case .nextEdit: return [k("down")]
        case .goToStart: return [k("home")]
        case .goToEnd: return [k("end")]
        case .setIn: return [k("i")]
        case .setOut: return [k("o")]
        case .clearInOut: return [k("x", .option)]
        case .selectClipRange: return [k("x")]
        case .blade: return [k("b"), k("k", .command)]
        case .bladeAllTracks: return [k("b", .shift)]
        case .delete: return [k("delete"), k("forwardDelete")]
        case .rippleDelete: return [k("delete", .shift)]
        case .deleteLeavingGap: return [k("delete", .option)]
        case .trimStartToPlayhead: return [k("[", .option)]
        case .trimEndToPlayhead: return [k("]", .option)]
        case .nudgeLeft: return [k(",")]
        case .nudgeRight: return [k(".")]
        case .selectClipAtPlayhead: return [k("c")]
        case .selectAll: return [k("a", .command)]
        case .deselectAll: return [k("a", .shift, .command), k("escape")]
        case .cut: return [k("x", .command)]
        case .copy: return [k("c", .command)]
        case .paste: return [k("v", .command)]
        case .duplicate: return [k("d", .command)]
        case .toggleLock: return [k("l", .command)]
        case .undo: return [k("z", .command)]
        case .redo: return [k("z", .shift, .command)]
        case .addText: return [k("t", .control)]
        case .connectToTimeline: return [k("q")]
        case .insertAtPlayhead: return [k("w")]
        case .appendToStoryline: return [k("e")]
        case .overwriteAtPlayhead: return [k("d")]
        case .zoomIn: return [k("=", .command), k("=")]
        case .zoomOut: return [k("-", .command), k("-")]
        case .zoomToFit: return [k("z", .shift), k("\\")]
        case .toggleSnapping: return [k("n")]
        case .toggleRipple: return []
        case .importMedia: return [k("i", .command)]
        case .newDraft: return [k("n", .shift, .command)]
        case .export: return [k("e", .command)]
        }
    }
}

/// The user's keyboard shortcuts: only their changes are stored; every other action keeps its factory shortcuts,
/// so new actions added in later versions get their defaults automatically.
public struct KeyBindings: Sendable, Equatable {
    /// Action → its full shortcut list. An empty list means the user removed every shortcut of that action.
    public private(set) var overrides: [EditorAction: [KeyShortcut]] = [:]

    public init(overrides: [EditorAction: [KeyShortcut]] = [:]) {
        self.overrides = overrides
        normalize()
    }

    public func shortcuts(for action: EditorAction) -> [KeyShortcut] { overrides[action] ?? action.defaultShortcuts }

    public func isCustomized(_ action: EditorAction) -> Bool { overrides[action] != nil }

    /// The action a shortcut triggers. When two actions share one (possible with factory shortcuts after the user
    /// rebinds), the first in catalogue order wins; `conflicts` reports it so Settings can show it.
    public func action(for shortcut: KeyShortcut) -> EditorAction? { lookup[shortcut] }

    /// Shortcut → action table, built once per change rather than on every key press.
    public var lookup: [KeyShortcut: EditorAction] {
        var map: [KeyShortcut: EditorAction] = [:]
        for a in EditorAction.allCases { for s in shortcuts(for: a) where map[s] == nil { map[s] = a } }
        return map
    }

    /// Shortcuts bound to more than one action.
    public var conflicts: [KeyShortcut: [EditorAction]] {
        var all: [KeyShortcut: [EditorAction]] = [:]
        for a in EditorAction.allCases { for s in shortcuts(for: a) { all[s, default: []].append(a) } }
        return all.filter { $0.value.count > 1 }
    }

    /// Adds `shortcut` to `action`, taking it away from any other action that had it. Returns the actions that lost it.
    @discardableResult
    public mutating func assign(_ shortcut: KeyShortcut, to action: EditorAction) -> [EditorAction] {
        var displaced: [EditorAction] = []
        for other in EditorAction.allCases where other != action {
            let list = shortcuts(for: other)
            if list.contains(shortcut) {
                overrides[other] = list.filter { $0 != shortcut }
                displaced.append(other)
            }
        }
        var mine = shortcuts(for: action)
        if !mine.contains(shortcut) { mine.append(shortcut) }
        overrides[action] = mine
        normalize()
        return displaced
    }

    public mutating func remove(_ shortcut: KeyShortcut, from action: EditorAction) {
        overrides[action] = shortcuts(for: action).filter { $0 != shortcut }
        normalize()
    }

    public mutating func reset(_ action: EditorAction) { overrides[action] = nil }

    public mutating func resetAll() { overrides = [:] }

    /// Drops overrides that equal the defaults, so "customized" means different and the file stays minimal.
    private mutating func normalize() {
        for (a, list) in overrides where list == a.defaultShortcuts { overrides[a] = nil }
    }
}

extension KeyBindings: Codable {
    /// Stored as `{"blade": ["b", "cmd+k"], …}`. Unknown actions and unparsable shortcuts are skipped, so a settings file
    /// from a newer or older version still loads.
    public init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode([String: [String]].self)) ?? [:]
        var o: [EditorAction: [KeyShortcut]] = [:]
        for (id, specs) in raw { if let a = EditorAction(rawValue: id) { o[a] = specs.compactMap { KeyShortcut(spec: $0) } } }
        self.init(overrides: o)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value.map(\.spec)) }))
    }
}
