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
    @State private var speedBase: (id: ItemID, source: TimeRange)?

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
            Section {
                keyed("Scale", 0.1...3, name: "Scale", key: "scale", { $0.transform.scale }, { $0.transform.scale = $1 })
                keyed("Zoom", 1...3, name: "Zoom", key: "zoom", { $0.transform.zoom }, { $0.transform.zoom = $1 })
                keyed("X", 0...1, name: "Move", key: "x", { $0.transform.position }, { $0.transform.position = $1 },
                      get: { $0.x }, set: { NormPoint($1, $0.y) })
                keyed("Y", 0...1, name: "Move", key: "y", { $0.transform.position }, { $0.transform.position = $1 },
                      get: { $0.y }, set: { NormPoint($0.x, $1) })
                keyed("Rotation", -180...180, name: "Rotate", key: "rot", { $0.transform.rotation }, { $0.transform.rotation = $1 })
                keyed("Opacity", 0...1, name: "Opacity", key: "opacity", { $0.opacity }, { $0.opacity = $1 })
            } header: {
                Text("Transform")
            } footer: {
                Text(local == nil ? "Move the playhead over this clip to add keyframes."
                                  : "◆ adds a keyframe at the playhead. Once a property has keyframes, dragging its slider sets the value at the playhead.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if let ref = item.content.mediaRef {
            Section("Speed") {
                LabeledContent("Speed") {
                    HStack {
                        Slider(value: Binding(get: { log2(ref.speed) }, set: { v in
                            editor.setSpeed(item.id, Self.niceSpeed(pow(2, v)), from: speedBase?.id == item.id ? speedBase?.source : nil)
                        }), in: -2...2) { editing in
                            // Every step of a drag is timed from the footage the clip had when the drag began.
                            if editing { speedBase = (item.id, ref.source) } else { speedBase = nil; editor.endGesture() }
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
                keyed("Gain (dB)", -40...12, name: "Gain", key: "gain", { $0.gain }, { $0.gain = $1 })
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

    /// The playhead in item time, or nil when it isn't over the item (keyframes go where the playhead is).
    private var local: RationalTime? {
        let t = editor.playhead - item.start
        return t >= .zero && t <= item.range.duration ? t : nil
    }

    /// Keys within half a frame of the playhead count as "here". In seconds: `frameDuration * 0.5` would round back up to
    /// a whole frame at the rate's own timescale (1/30 × 0.5 → 1/30).
    private var halfFrame: RationalTime { RationalTime(seconds: editor.timeline.canvas.frameRate.frameDuration.seconds / 2) }

    /// A keyframeable number property.
    private func keyed(_ label: String, _ range: ClosedRange<Double>, name: String, key: String,
                       _ read: @escaping @Sendable (Item) -> Param<Double>, _ write: @escaping @Sendable (inout Item, Param<Double>) -> Void) -> some View {
        keyed(label, range, name: name, key: key, read, write, get: { $0 }, set: { $1 })
    }

    /// A keyframeable property shown as one number (`get`/`set` pick a component, e.g. X of a position).
    private func keyed<V: ClipperCore.Animatable>(_ label: String, _ range: ClosedRange<Double>, name: String, key: String,
                                      _ read: @escaping @Sendable (Item) -> Param<V>, _ write: @escaping @Sendable (inout Item, Param<V>) -> Void,
                                      get: @escaping @Sendable (V) -> Double, set: @escaping @Sendable (V, Double) -> V) -> some View {
        let param = read(item), t = local, half = halfFrame
        let here = t.flatMap { param.key(at: $0, tolerance: half) } != nil
        let value = get(param.value(at: t ?? .zero))
        let keys = param.keys.map(\.time)
        return LabeledContent {
            HStack(spacing: 4) {
                if param.isAnimated {
                    Button { if let k = keys.last(where: { $0 < (t ?? .zero) - half }) { editor.seek(to: item.start + k) } } label: { Image(systemName: "chevron.left") }
                        .disabled(!keys.contains { $0 < (t ?? .zero) - half }).help("Previous keyframe")
                }
                Button {
                    guard let t else { return }
                    modify(here ? "Remove Keyframe" : "Add Keyframe") { item in
                        let p = read(item)
                        write(&item, here ? p.removingKey(at: t, tolerance: half) : p.setting(p.value(at: t), at: t, tolerance: half))
                    }
                } label: {
                    Image(systemName: here ? "diamond.fill" : "diamond").foregroundStyle(param.isAnimated ? Color.accentColor : .secondary)
                }
                .disabled(t == nil)
                .help(here ? "Remove the keyframe at the playhead" : "Add a keyframe at the playhead")
                if param.isAnimated {
                    Button { if let k = keys.first(where: { $0 > (t ?? .zero) + half }) { editor.seek(to: item.start + k) } } label: { Image(systemName: "chevron.right") }
                        .disabled(!keys.contains { $0 > (t ?? .zero) + half }).help("Next keyframe")
                }
                Slider(value: Binding(get: { value }, set: { v in
                    modify(name, key: key) { item in
                        let p = read(item)
                        if p.isAnimated, let t {
                            write(&item, p.setting(set(p.value(at: t), v), at: t, tolerance: half))
                        } else {
                            write(&item, .constant(set(p.value(at: .zero), v)))
                        }
                    }
                }), in: range) { editing in if !editing { editor.endGesture() } }
                .disabled(param.isAnimated && t == nil)
                Text(String(format: "%.2f", value)).font(.caption.monospacedDigit()).frame(width: 44, alignment: .trailing)
            }
            .buttonStyle(.borderless)
        } label: { Text(label) }
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
