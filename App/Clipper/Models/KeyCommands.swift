import AppKit
import ClipperCore
import SwiftUI

extension KeyShortcut {
    /// Function-key characters AppKit uses for named keys (menus and `NSEvent.characters`).
    private static let appKitCharacters: [String: Int] = [
        "space": 0x20, "return": 0x0D, "enter": 0x03, "tab": 0x09, "escape": 0x1B, "delete": 0x08,
        "forwardDelete": NSDeleteFunctionKey, "left": NSLeftArrowFunctionKey, "right": NSRightArrowFunctionKey,
        "up": NSUpArrowFunctionKey, "down": NSDownArrowFunctionKey, "home": NSHomeFunctionKey, "end": NSEndFunctionKey,
        "pageUp": NSPageUpFunctionKey, "pageDown": NSPageDownFunctionKey,
        "f1": NSF1FunctionKey, "f2": NSF2FunctionKey, "f3": NSF3FunctionKey, "f4": NSF4FunctionKey, "f5": NSF5FunctionKey,
        "f6": NSF6FunctionKey, "f7": NSF7FunctionKey, "f8": NSF8FunctionKey, "f9": NSF9FunctionKey, "f10": NSF10FunctionKey,
        "f11": NSF11FunctionKey, "f12": NSF12FunctionKey,
    ]

    /// Named keys by virtual key code (layout-independent).
    private static let keyCodes: [UInt16: String] = [
        49: "space", 36: "return", 76: "enter", 48: "tab", 53: "escape", 51: "delete", 117: "forwardDelete",
        123: "left", 124: "right", 125: "down", 126: "up", 115: "home", 119: "end", 116: "pageUp", 121: "pageDown",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10",
        103: "f11", 111: "f12",
    ]

    /// The shortcut a key-down event represents. Characters come from the current layout without modifiers applied,
    /// so ⇧, is "shift+," rather than "<"; nil for bare modifier presses and dead keys.
    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods = Set<Modifier>()
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }
        if let named = Self.keyCodes[event.keyCode] {
            self.init(named, mods)
            return
        }
        guard let chars = event.characters(byApplyingModifiers: []), chars.count == 1,
              let scalar = chars.unicodeScalars.first, scalar.value >= 0x20, scalar.value < 0xF700 else { return nil }
        self.init(chars, mods)
    }

    /// For SwiftUI menu items.
    var keyEquivalent: KeyEquivalent? {
        if let code = Self.appKitCharacters[key], let scalar = UnicodeScalar(code) {
            return switch key {
            case "space": .space
            case "return": .return
            case "tab": .tab
            case "escape": .escape
            case "delete": .delete
            case "forwardDelete": .deleteForward
            case "left": .leftArrow
            case "right": .rightArrow
            case "up": .upArrow
            case "down": .downArrow
            case "home": .home
            case "end": .end
            case "pageUp": .pageUp
            case "pageDown": .pageDown
            default: KeyEquivalent(Character(scalar))
            }
        }
        return key.first.map { KeyEquivalent($0) }
    }

    var eventModifiers: EventModifiers {
        var m: EventModifiers = []
        if modifiers.contains(.command) { m.insert(.command) }
        if modifiers.contains(.shift) { m.insert(.shift) }
        if modifiers.contains(.option) { m.insert(.option) }
        if modifiers.contains(.control) { m.insert(.control) }
        return m
    }

    /// For AppKit menu items (the timeline's context menu).
    var appKitKeyEquivalent: (String, NSEvent.ModifierFlags) {
        let s = Self.appKitCharacters[key].flatMap(UnicodeScalar.init).map { String(Character($0)) } ?? key
        var m: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { m.insert(.command) }
        if modifiers.contains(.shift) { m.insert(.shift) }
        if modifiers.contains(.option) { m.insert(.option) }
        if modifiers.contains(.control) { m.insert(.control) }
        return (s, m)
    }
}

extension View {
    /// Attaches the action's first menu-safe shortcut (one with ⌘ or ⌃). Plain-key shortcuts stay off menus — as key
    /// equivalents they would fire before a focused text field could type the key — and are handled by `KeyCommandMonitor`.
    func shortcut(_ action: EditorAction, in bindings: KeyBindings) -> some View {
        let s = bindings.shortcuts(for: action).first(where: \.isMenuSafe)
        return keyboardShortcut(s.flatMap { s in s.keyEquivalent.map { KeyboardShortcut($0, modifiers: s.eventModifiers) } })
    }
}

/// Routes key presses in the main window to editor actions through the user's key bindings. A local event monitor sees
/// keys before menus and the focused view, so single-key NLE shortcuts work wherever focus is — except while typing in a
/// text field (everything passes through), in another window (Settings records shortcuts there), or under a sheet.
@MainActor
final class KeyCommandMonitor {
    private var monitor: Any?
    private(set) weak var window: NSWindow?
    private weak var model: AppModel?
    /// Rebuilt only when the bindings change, not on every key press.
    private var cached: (bindings: KeyBindings, lookup: [KeyShortcut: EditorAction])?

    init(model: AppModel) { self.model = model }

    func attach(to window: NSWindow?) {
        self.window = window
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event) == true }
            return consumed ? nil : event
        }
    }

    func detach() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.attachedSheet == nil,
              let model, let shortcut = KeyShortcut(event: event) else { return false }
        if let responder = window.firstResponder {
            if responder is NSText { return false }
            // Lists keep their own arrow-key navigation.
            if responder is NSTableView || responder is NSOutlineView || responder is NSCollectionView,
               shortcut.modifiers.isEmpty, ["up", "down", "return"].contains(shortcut.key) { return false }
        }
        let bindings = model.settings.keyBindings
        if cached?.bindings != bindings { cached = (bindings, bindings.lookup) }
        guard let action = cached?.lookup[shortcut], model.canPerform(action) else { return false }
        // A held key fires once (frame steps and nudges excepted). The repeats are swallowed here: passed on, they'd
        // beep, or reach the menu, whose key equivalents do auto-repeat.
        if event.isARepeat, !Self.repeats(action) { return true }
        model.perform(action)
        return true
    }

    /// Actions that keep going while their key is held.
    private static func repeats(_ action: EditorAction) -> Bool {
        [.previousFrame, .nextFrame, .back10Frames, .forward10Frames, .nudgeLeft, .nudgeRight, .previousEdit, .nextEdit].contains(action)
    }
}

/// Hands the hosting window to the key monitor (SwiftUI doesn't expose it directly).
struct KeyMonitorHost: NSViewRepresentable {
    let monitor: KeyCommandMonitor

    func makeNSView(context: Context) -> NSView {
        let v = WindowReporter()
        v.onWindow = { [weak monitor] w in monitor?.attach(to: w) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {}

    final class WindowReporter: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}
