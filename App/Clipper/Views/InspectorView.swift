import ClipperCore
import SwiftUI

/// Properties of the selected item (or the timeline when nothing is selected).
struct InspectorView: View {
    @Bindable var editor: EditorModel

    var body: some View {
        Form {
            if editor.selection.count == 1, let id = editor.selection.first, let item = editor.timeline.item(id) {
                ItemInspector(editor: editor, item: item)
            } else if editor.selection.count > 1 {
                Section { Text("\(editor.selection.count) items selected").foregroundStyle(.secondary) }
            } else {
                TimelineInspector(editor: editor)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ItemInspector: View {
    @Bindable var editor: EditorModel
    let item: Item

    private func modify(_ name: String, key: String? = nil, _ change: @escaping @Sendable (inout Item) -> Void) {
        editor.perform(ModifyItem(item.id, name: name, coalescingKey: key.map { "\(item.id)-\($0)" }, change))
    }

    var body: some View {
        Section("Item") {
            LabeledContent("Name", value: item.name.isEmpty ? "—" : item.name)
            LabeledContent("Start", value: Timecode.string(item.start.seconds, rate: editor.timeline.canvas.frameRate))
            LabeledContent("Duration", value: String(format: "%.2fs", item.range.duration.seconds))
            LabeledContent("Origin", value: item.origin.isAuto ? "Automatic draft" : "Added by you")
            Toggle("Locked (kept when re-drafting)", isOn: Binding(get: { item.locked }, set: { v in modify(v ? "Lock" : "Unlock") { $0.locked = v } }))
        }
        switch item.content {
        case .text(let t):
            Section("Text") {
                TextField("Text", text: Binding(get: { t.text }, set: { v in modify("Edit Text", key: "text") { if case .text(var c) = $0.content { c.text = v; $0.content = .text(c) } } }),
                          axis: .vertical)
                    .lineLimit(1...5)
                StylePicker(editor: editor, selection: t.style) { s in modify("Change Style") { if case .text(var c) = $0.content { c.style = s; $0.content = .text(c) } } }
                LabeledContent("Position") {
                    HStack(spacing: 4) {
                        ForEach([("Top", 0.13), ("Middle", 0.5), ("Lower third", 0.72), ("Bottom", 0.86)], id: \.0) { name, y in
                            Button(name) { modify("Move Text") { $0.transform.position = .constant(NormPoint(0.5, y)) } }
                        }
                    }
                    .controlSize(.small)
                }
            }
        case .caption(let c):
            Section("Caption") {
                TextField("Words", text: Binding(get: { c.text }, set: { v in
                    modify("Edit Caption", key: "caption") { item in
                        guard case .caption(var cap) = item.content else { return }
                        cap.words = Self.retime(cap.words, to: v.split(separator: " ").map(String.init))
                        item.content = .caption(cap)
                    }
                }))
                StylePicker(editor: editor, selection: c.style) { s in modify("Change Caption Style") { if case .caption(var cap) = $0.content { cap.style = s; $0.content = .caption(cap) } } }
            }
        default: EmptyView()
        }
        if editor.timeline.tracks.first(where: { $0.items.contains { $0.id == item.id } })?.kind.isVisual == true {
            Section("Transform") {
                slider("Scale", item.transform.scale.value(at: .zero), 0.1...3) { v in modify("Scale", key: "scale") { $0.transform.scale = .constant(v) } }
                slider("Zoom", item.transform.zoom.value(at: .zero), 1...3) { v in modify("Zoom", key: "zoom") { $0.transform.zoom = .constant(v) } }
                slider("X", item.transform.position.value(at: .zero).x, 0...1) { v in modify("Move", key: "x") { $0.transform.position = .constant(NormPoint(v, $0.transform.position.value(at: .zero).y)) } }
                slider("Y", item.transform.position.value(at: .zero).y, 0...1) { v in modify("Move", key: "y") { $0.transform.position = .constant(NormPoint($0.transform.position.value(at: .zero).x, v)) } }
                slider("Rotation", item.transform.rotation.value(at: .zero), -180...180) { v in modify("Rotate", key: "rot") { $0.transform.rotation = .constant(v) } }
                slider("Opacity", item.opacity.value(at: .zero), 0...1) { v in modify("Opacity", key: "opacity") { $0.opacity = .constant(v) } }
                if item.transform.zoom.isAnimated || item.transform.focus.isAnimated {
                    Text("Animated by the draft (zoom/reframe). Editing here replaces the animation.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if let ref = item.content.mediaRef {
            Section("Speed") {
                LabeledContent("Speed") {
                    HStack {
                        Slider(value: Binding(get: { log2(ref.speed) }, set: { v in editor.setSpeed(item.id, Self.niceSpeed(pow(2, v))) }), in: -2...2) { editing in
                            if !editing { editor.endGesture() }
                        }
                        Text("\(Int((ref.speed * 100).rounded()))%").font(.caption.monospacedDigit()).frame(width: 44, alignment: .trailing)
                    }
                }
                HStack(spacing: 4) {
                    ForEach([0.5, 1, 1.5, 2], id: \.self) { v in
                        Button(v == 1 ? "Normal" : "\(Int(v * 100))%") { editor.setSpeed(item.id, v); editor.endGesture() }
                    }
                }
                .controlSize(.small)
                Text(editor.settings.editing.rippleByDefault ? "Clips after this one move to make room (ripple is on)."
                                                            : "With ripple off, a slower clip can't grow into the next one.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Audio") {
                slider("Gain (dB)", item.gain.isAnimated ? 0 : item.gain.value(at: .zero), -40...12) { v in modify("Gain", key: "gain") { $0.gain = .constant(v) } }
                slider("Fade in (s)", item.fadeIn.seconds, 0...3) { v in modify("Fade In", key: "fi") { $0.fadeIn = RationalTime(seconds: v) } }
                slider("Fade out (s)", item.fadeOut.seconds, 0...3) { v in modify("Fade Out", key: "fo") { $0.fadeOut = RationalTime(seconds: v) } }
            }
        }
    }

    /// Slider speeds snap to whole percentages (and exactly 100%) so the label and the clip agree.
    nonisolated static func niceSpeed(_ v: Double) -> Double {
        let pct = (v * 100).rounded()
        return abs(pct - 100) < 3 ? 1 : pct / 100
    }

    private func slider(_ label: String, _ value: Double, _ range: ClosedRange<Double>, _ set: @escaping @MainActor (Double) -> Void) -> some View {
        LabeledContent(label) {
            HStack {
                Slider(value: Binding(get: { value }, set: set), in: range) { editing in if !editing { editor.endGesture() } }
                Text(String(format: "%.2f", value)).font(.caption.monospacedDigit()).frame(width: 44, alignment: .trailing)
            }
        }
    }

    /// Keeps word timing when the user corrects caption text (extra/missing words share the page time).
    nonisolated static func retime(_ words: [CaptionContent.Word], to texts: [String]) -> [CaptionContent.Word] {
        guard !texts.isEmpty else { return [] }
        if texts.count == words.count { return zip(words, texts).map { var w = $0; w.text = $1; return w } }
        let start = words.first?.start ?? .zero, end = words.last?.end ?? RationalTime(seconds: 1)
        let step = (end - start).seconds / Double(texts.count)
        return texts.enumerated().map { i, t in
            CaptionContent.Word(text: t, start: start + RationalTime(seconds: step * Double(i)), end: start + RationalTime(seconds: step * Double(i + 1)))
        }
    }
}

private struct StylePicker: View {
    @Bindable var editor: EditorModel
    let selection: String
    let set: (String) -> Void
    var body: some View {
        Picker("Style", selection: Binding(get: { selection }, set: set)) {
            ForEach(editor.timeline.styles.keys.sorted(), id: \.self) { Text($0).tag($0) }
        }
    }
}

private struct TimelineInspector: View {
    @Bindable var editor: EditorModel
    var body: some View {
        let tl = editor.timeline
        Section("Timeline") {
            LabeledContent("Name", value: tl.name)
            LabeledContent("Canvas", value: "\(tl.canvas.width)×\(tl.canvas.height) @ \(tl.canvas.frameRate) fps")
            LabeledContent("Duration", value: String(format: "%.1fs", tl.duration.seconds))
            LabeledContent("Loudness target", value: tl.loudnessTarget.map { "\(Int($0)) LUFS" } ?? "—")
            if let p = tl.provenance { LabeledContent("Template", value: "\(p.template) v\(p.templateVersion), seed \(p.seed)") }
        }
        if !tl.attributions.isEmpty {
            Section("Credits (add to your description)") {
                ForEach(tl.attributions, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
            }
        }
        Section {
            Text("Select an item to edit it. Drag clips, music and titles from the browser onto the timeline (hold ⌥ to insert instead of overwrite). I / O mark a range that ⌫ removes. Right-click a clip for speed and more. Shortcuts are in Settings ▸ Shortcuts.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
