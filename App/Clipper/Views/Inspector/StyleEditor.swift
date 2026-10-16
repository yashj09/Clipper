import AppKit
import ClipperCore
import SwiftUI

extension RGBA {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    init(_ color: Color) {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent))
    }
}

/// Essential Graphics-style editing of a text style (titles and captions). Styles are shared by name, so a change
/// normally applies to every item using the style ("All N captions"); "Only this one" first gives the item its own copy.
struct StyleEditor: View {
    @Bindable var editor: EditorModel
    let styleKey: String
    let target: ApplyStyleToAll.Target
    /// The item being edited (nil when editing the style itself, e.g. from the Captions tab).
    var itemID: ItemID?
    @State private var onlyThis = false

    private var style: TextStyle { editor.timeline.styles[styleKey] ?? TextStyle() }

    /// Items using this style.
    private var users: [Item] {
        editor.timeline.allItems.filter { item in
            switch (target, item.content) {
            case (.captions, .caption(let c)): c.style == styleKey
            case (.text, .text(let t)): t.style == styleKey
            default: false
            }
        }
    }

    private var noun: String { target == .captions ? "caption" : "text" }

    var body: some View {
        let count = users.count
        if itemID != nil, count > 1 {
            Picker("Changes apply to", selection: $onlyThis) {
                Text("All \(count) \(noun)s with “\(styleKey)”").tag(false)
                Text("Only this \(noun)").tag(true)
            }
            .pickerStyle(.radioGroup)
        }
        FontRow(font: style.font) { f in edit("Font", nil) { $0.font = f } }
        LabeledContent("Size") {
            HStack {
                Slider(value: binding(\.size, "size"), in: 0.02...0.12) { e in if !e { editor.endGesture() } }
                Text("\(Int((style.size * Double(editor.timeline.canvas.height)).rounded())) px").font(.caption.monospacedDigit()).frame(width: 50, alignment: .trailing)
            }
        }
        ColorPicker("Text colour", selection: colorBinding(\.color, "color"), supportsOpacity: false)
        Toggle("UPPERCASE", isOn: Binding(get: { style.uppercase }, set: { v in edit("Uppercase", nil) { $0.uppercase = v } }))
        Picker("Align", selection: Binding(get: { style.alignment }, set: { v in edit("Align", nil) { $0.alignment = v } })) {
            Text("Left").tag(TextStyle.Alignment.left); Text("Centre").tag(TextStyle.Alignment.center); Text("Right").tag(TextStyle.Alignment.right)
        }
        .pickerStyle(.segmented)

        Toggle("Outline", isOn: Binding(get: { style.stroke != nil && style.strokeWidth > 0 }, set: { on in
            edit("Outline", nil) { s in s.stroke = on ? (s.stroke ?? .black) : nil; s.strokeWidth = on ? max(s.strokeWidth, 0.08) : 0 }
        }))
        if style.stroke != nil, style.strokeWidth > 0 {
            ColorPicker("Outline colour", selection: Binding(get: { (style.stroke ?? .black).color }, set: { c in edit("Outline Colour", "strokeColor") { $0.stroke = RGBA(c) } }))
            LabeledContent("Outline width") {
                Slider(value: binding(\.strokeWidth, "strokeWidth"), in: 0.01...0.25) { e in if !e { editor.endGesture() } }
            }
        }
        Toggle("Shadow", isOn: Binding(get: { style.shadow != nil }, set: { on in edit("Shadow", nil) { $0.shadow = on ? TextStyle.Shadow() : nil } }))
        Toggle("Background box", isOn: Binding(get: { style.box != nil }, set: { on in
            edit("Background", nil) { $0.box = on ? TextStyle.Box(color: RGBA(0, 0, 0, 0.6)) : nil }
        }))
        if let box = style.box {
            ColorPicker("Box colour", selection: Binding(get: { box.color.color }, set: { c in edit("Box Colour", "boxColor") { $0.box?.color = RGBA(c) } }), supportsOpacity: true)
            LabeledContent("Box padding") {
                Slider(value: Binding(get: { box.padding }, set: { v in edit("Box Padding", "boxPad") { $0.box?.padding = v } }), in: 0...1) { e in if !e { editor.endGesture() } }
            }
        }

        LabeledContent("Position X") {
            Slider(value: Binding(get: { style.position.x }, set: { v in move(NormPoint(v, style.position.y)) }), in: 0.05...0.95) { e in if !e { editor.endGesture() } }
        }
        LabeledContent("Position Y") {
            Slider(value: Binding(get: { style.position.y }, set: { v in move(NormPoint(style.position.x, v)) }), in: 0.05...0.95) { e in if !e { editor.endGesture() } }
        }
        LabeledContent("Max width") {
            Slider(value: binding(\.maxWidth, "maxWidth"), in: 0.3...1) { e in if !e { editor.endGesture() } }
        }
        LabeledContent("Line spacing") {
            Slider(value: binding(\.lineSpacing, "lineSpacing"), in: 0.8...1.8) { e in if !e { editor.endGesture() } }
        }

        if target == .captions {
            Toggle("Highlight the spoken word", isOn: Binding(get: { style.highlight != nil }, set: { on in
                edit("Highlight", nil) { $0.highlight = on ? TextStyle.Highlight(color: RGBA(hex: "#FFD60A")) : nil }
            }))
            if let hl = style.highlight {
                ColorPicker("Highlight colour", selection: Binding(get: { (hl.color ?? .white).color }, set: { c in edit("Highlight Colour", "hlColor") { $0.highlight?.color = RGBA(c) } }))
                Toggle("Box behind the spoken word", isOn: Binding(get: { hl.box != nil }, set: { on in
                    edit("Highlight Box", nil) { $0.highlight?.box = on ? RGBA(hex: "#7C3AED") : nil }
                }))
                if let b = hl.box {
                    ColorPicker("Word box colour", selection: Binding(get: { b.color }, set: { c in edit("Word Box Colour", "hlBoxColor") { $0.highlight?.box = RGBA(c) } }))
                }
            }
            Toggle("Colour keywords", isOn: Binding(get: { style.emphasisColor != nil }, set: { on in
                edit("Keyword Colour", nil) { $0.emphasisColor = on ? RGBA(hex: "#4ADE80") : nil }
            }))
            if let e = style.emphasisColor {
                ColorPicker("Keyword colour", selection: Binding(get: { e.color }, set: { c in edit("Keyword Colour", "emphColor") { $0.emphasisColor = RGBA(c) } }))
            }
            Picker("Animation", selection: Binding(get: { style.animation }, set: { v in edit("Animation", nil) { $0.animation = v } })) {
                Text("None").tag(TextStyle.Animation.none); Text("Pop in").tag(TextStyle.Animation.pop)
                Text("Fade in").tag(TextStyle.Animation.fade); Text("Word by word").tag(TextStyle.Animation.wordByWord)
            }
        }
        Button("Use “\(styleKey)” for all \(noun)s") { editor.perform(ApplyStyleToAll(target, style: styleKey)) }
            .help("Give every \(noun) this look and position (locked ones are left alone)")
    }

    // MARK: Editing

    private func binding(_ path: WritableKeyPath<TextStyle, Double> & Sendable, _ key: String) -> Binding<Double> {
        Binding(get: { style[keyPath: path] }, set: { v in edit(key, key) { $0[keyPath: path] = v } })
    }

    private func colorBinding(_ path: WritableKeyPath<TextStyle, RGBA> & Sendable, _ key: String) -> Binding<Color> {
        Binding(get: { style[keyPath: path].color }, set: { c in edit("Colour", key) { $0[keyPath: path] = RGBA(c) } })
    }

    /// Changes the style (for all its users), or — with "Only this one" — a copy given to just this item.
    /// `field` merges consecutive changes of a continuous control (slider, colour well) into one undo step; toggles and
    /// pickers pass nil so each change is its own step.
    private func edit(_ name: String, _ field: String?, _ change: @escaping @Sendable (inout TextStyle) -> Void) {
        var s = style
        change(&s)
        if onlyThis, let itemID, users.count > 1 {
            let key = uniqueKey(styleKey)
            let newStyle = s, target = target
            editor.perform(Batch([SetStyle(key, newStyle), ModifyItem(itemID, name: "") { item in
                switch (target, item.content) {
                case (.captions, .caption(var c)): c.style = key; item.content = .caption(c)
                case (.text, .text(var t)): t.style = key; item.content = .text(t)
                default: break
                }
            }], name: "Change \(name)"))
            return
        }
        let key = styleKey, newStyle = s
        editor.perform(ModifyTimeline(name: "Change \(name)", coalescingKey: field.map { "style-\(key)-\($0)" }) { $0.styles[key] = newStyle })
    }

    /// Moves the style's anchor and every item using it (titles and captions are placed from their style).
    private func move(_ p: NormPoint) {
        var s = style
        s.position = p
        if onlyThis, let itemID, users.count > 1 {
            let key = uniqueKey(styleKey), newStyle = s, target = target
            editor.perform(Batch([SetStyle(key, newStyle), ModifyItem(itemID, name: "") { item in
                item.transform.position = .constant(p)
                switch (target, item.content) {
                case (.captions, .caption(var c)): c.style = key; item.content = .caption(c)
                case (.text, .text(var t)): t.style = key; item.content = .text(t)
                default: break
                }
            }], name: "Move"))
            return
        }
        let key = styleKey, newStyle = s, ids = Set(users.filter { !$0.locked }.map(\.id))
        editor.perform(ModifyTimeline(name: "Move", coalescingKey: "style-\(key)-pos") { t in
            t.styles[key] = newStyle
            for ti in t.tracks.indices where !t.tracks[ti].locked {
                for ii in t.tracks[ti].items.indices where ids.contains(t.tracks[ti].items[ii].id) {
                    t.tracks[ti].items[ii].transform.position = .constant(p)
                }
            }
        })
    }

    private func uniqueKey(_ base: String) -> String {
        var n = 2
        while editor.timeline.styles["\(base) \(n)"] != nil { n += 1 }
        return "\(base) \(n)"
    }
}

/// Font family + weight, stored as a PostScript name.
struct FontRow: View {
    let font: String
    let set: (String) -> Void

    static let families: [String] = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }

    var body: some View {
        let family = NSFont(name: font, size: 12)?.familyName ?? "Helvetica"
        let members = (NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []).compactMap { m -> (String, String)? in
            guard let ps = m.first as? String, let weight = m[1] as? String else { return nil }
            return (ps, weight)
        }
        LabeledContent("Font") {
            HStack {
                Menu(family) {
                    ForEach(Self.families, id: \.self) { f in
                        Button(f) {
                            let first = (NSFontManager.shared.availableMembers(ofFontFamily: f) ?? []).compactMap { $0.first as? String }
                            // Prefer a bold face: on-video text is usually heavy.
                            set(first.first { $0.localizedCaseInsensitiveContains("bold") || $0.localizedCaseInsensitiveContains("heavy") } ?? first.first ?? f)
                        }
                    }
                }
                .frame(maxWidth: 170)
                Picker("", selection: Binding(get: { font }, set: set)) {
                    ForEach(members, id: \.0) { Text($0.1).tag($0.0) }
                    if !members.contains(where: { $0.0 == font }) { Text(font).tag(font) }
                }
                .labelsHidden()
                .frame(maxWidth: 110)
            }
        }
    }
}
