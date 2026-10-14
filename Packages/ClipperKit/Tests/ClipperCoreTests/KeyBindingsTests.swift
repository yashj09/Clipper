import Foundation
import Testing
@testable import ClipperCore

@Suite struct KeyShortcutTests {
    @Test func parsesAndPrintsSpecs() throws {
        let s = try #require(KeyShortcut(spec: "shift+cmd+K"))
        #expect(s.key == "k" && s.modifiers == [.shift, .command])
        #expect(s.spec == "shift+cmd+k")          // modifiers in ⌃⌥⇧⌘ order
        #expect(s.display == "⇧⌘K")
        #expect(KeyShortcut(spec: "option+[")?.display == "⌥[")
        #expect(KeyShortcut(spec: "space")?.display == "Space")
        #expect(KeyShortcut(spec: "shift+Delete")?.key == "delete")
        #expect(KeyShortcut(spec: "cmd++")?.key == "+")
        #expect(KeyShortcut(spec: "hyper+k") == nil)
        #expect(KeyShortcut(spec: "cmd+") == nil)
        #expect(KeyShortcut(spec: "banana") == nil)
    }

    @Test func onlyCommandOrControlShortcutsGoOnMenus() {
        #expect(KeyShortcut("k", [.command]).isMenuSafe)
        #expect(KeyShortcut("t", [.control]).isMenuSafe)
        #expect(!KeyShortcut("b").isMenuSafe)
        #expect(!KeyShortcut("[", [.option]).isMenuSafe)
    }

    @Test func everyActionHasAUniqueDefaultShortcut() {
        var seen: [KeyShortcut: EditorAction] = [:]
        for a in EditorAction.allCases {
            for s in a.defaultShortcuts {
                #expect(seen[s] == nil, "\(s) is the default of both \(seen[s]!) and \(a)")
                seen[s] = a
            }
        }
        #expect(KeyBindings().conflicts.isEmpty)
    }
}

@Suite struct KeyBindingsTests {
    @Test func defaultsResolve() {
        let b = KeyBindings()
        #expect(b.action(for: KeyShortcut("b")) == .blade)
        #expect(b.action(for: KeyShortcut("k", [.command])) == .blade)
        #expect(b.action(for: KeyShortcut("space")) == .playPause)
        #expect(b.action(for: KeyShortcut("y")) == nil)
    }

    @Test func assigningStealsTheShortcutFromItsOldAction() {
        var b = KeyBindings()
        let displaced = b.assign(KeyShortcut("b"), to: .addText)
        #expect(displaced == [.blade])
        #expect(b.action(for: KeyShortcut("b")) == .addText)
        #expect(b.shortcuts(for: .blade) == [KeyShortcut("k", [.command])])
        #expect(b.shortcuts(for: .addText) == [KeyShortcut("t", [.control]), KeyShortcut("b")])
        #expect(b.conflicts.isEmpty)
    }

    @Test func removingAndResetting() {
        var b = KeyBindings()
        b.remove(KeyShortcut("space"), from: .playPause)
        #expect(b.shortcuts(for: .playPause).isEmpty && b.isCustomized(.playPause))
        #expect(b.action(for: KeyShortcut("space")) == nil)
        b.reset(.playPause)
        #expect(!b.isCustomized(.playPause) && b.action(for: KeyShortcut("space")) == .playPause)
        // Re-adding exactly the defaults isn't a customization.
        b.remove(KeyShortcut("j"), from: .shuttleBackward)
        b.assign(KeyShortcut("j"), to: .shuttleBackward)
        #expect(!b.isCustomized(.shuttleBackward))
    }

    @Test func storesOnlyChangesAndToleratesJunk() throws {
        var b = KeyBindings()
        b.assign(KeyShortcut("x", [.control]), to: .toggleRipple)
        let json = String(decoding: try JSONEncoder().encode(b), as: UTF8.self)
        #expect(json == #"{"toggleRipple":["ctrl+x"]}"#)

        let data = Data(#"{"toggleRipple": ["ctrl+x", "nonsense+q"], "futureAction": ["f"], "blade": []}"#.utf8)
        let decoded = try JSONDecoder().decode(KeyBindings.self, from: data)
        #expect(decoded.shortcuts(for: .toggleRipple) == [KeyShortcut("x", [.control])])
        #expect(decoded.shortcuts(for: .blade).isEmpty)
        #expect(decoded.shortcuts(for: .playPause) == EditorAction.playPause.defaultShortcuts)
    }

    @Test func settingsWithoutBindingsStillLoad() throws {
        let s = try JSONDecoder().decode(ClipperSettings.self, from: Data(#"{"editing": {"snapping": false}}"#.utf8))
        #expect(s.keyBindings == KeyBindings() && !s.editing.snapping)
        let bad = try JSONDecoder().decode(ClipperSettings.self, from: Data(#"{"keyBindings": 42}"#.utf8))
        #expect(bad.keyBindings == KeyBindings())
    }
}
