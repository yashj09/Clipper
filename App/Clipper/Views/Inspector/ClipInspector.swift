import ClipperCore
import SwiftUI

/// The editing panel, in Premiere's terms: Clip (Effect Controls + Essential Graphics), Color (Lumetri basics),
/// Captions and Project (sequence settings).
struct InspectorView: View {
    @Bindable var model: AppModel
    @Bindable var editor: EditorModel
    @AppStorage("inspectorTab") private var tab = "clip"

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Clip").tag("clip"); Text("Color").tag("color"); Text("Captions").tag("captions"); Text("Project").tag("project")
            }
            .pickerStyle(.segmented).labelsHidden().padding(8)
            Divider()
            Form {
                switch tab {
                case "color": ColorInspector(editor: editor)
                case "captions": CaptionsInspector(editor: editor)
                case "project": ProjectInspector(editor: editor)
                default:
                    if editor.selection.count == 1, let id = editor.selection.first, let item = editor.timeline.item(id) {
                        ClipInspector(model: model, editor: editor, item: item)
                    } else if editor.selection.count > 1 {
                        MultiSelectionInspector(model: model, editor: editor)
                    } else {
                        Section {
                            Text("Select a clip, title or caption on the timeline to edit it here.").foregroundStyle(.secondary)
                            Text("Drag clips, music and titles from the browser onto the timeline (hold ⌥ to insert). I / O mark a range that ⌫ removes. Right-click a clip or a track for more. Shortcuts are in Settings ▸ Shortcuts.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

/// Effect Controls for one item.
struct ClipInspector: View {
    @Bindable var model: AppModel
    @Bindable var editor: EditorModel
    let item: Item
    @State private var speedBase: (id: ItemID, source: TimeRange)?

    private var track: Track? { editor.timeline.tracks.first { $0.items.contains { $0.id == item.id } } }
    private var isVisual: Bool { track?.kind.isVisual == true }
    private var isFootage: Bool {
        switch item.content { case .media, .image: isVisual; default: false }
    }
    private var rate: FrameRate { editor.timeline.canvas.frameRate }

    private func modify(_ name: String, key: String? = nil, _ change: @escaping @Sendable (inout Item) -> Void) {
        editor.perform(ModifyItem(item.id, name: name, coalescingKey: key.map { "\(item.id)-\($0)" }, change))
    }

    var body: some View {
        clipSection
        switch item.content {
        case .text(let t):
            Section("Text") {
                TextField("Text", text: Binding(get: { t.text }, set: { v in modify("Edit Text", key: "text") { if case .text(var c) = $0.content { c.text = v; $0.content = .text(c) } } }),
                          axis: .vertical)
                    .lineLimit(1...6)
                StylePicker(editor: editor, selection: t.style) { s in modify("Change Style") { if case .text(var c) = $0.content { c.style = s; $0.content = .text(c) } } }
            }
            Section("Text style") { StyleEditor(editor: editor, styleKey: t.style, target: .text, itemID: item.id) }
        case .caption(let c):
            Section("Caption") {
                LiveTextField(title: "Words", value: c.text) { v in
                    modify("Edit Caption", key: "caption") { item in
                        guard case .caption(var cap) = item.content else { return }
                        cap.words = Self.retime(cap.words, to: v.split(separator: " ").map(String.init))
                        item.content = .caption(cap)
                    }
                }
                StylePicker(editor: editor, selection: c.style) { s in modify("Change Caption Style") { if case .caption(var cap) = $0.content { cap.style = s; $0.content = .caption(cap) } } }
            }
            Section("Caption style") { StyleEditor(editor: editor, styleKey: c.style, target: .captions, itemID: item.id) }
        default: EmptyView()
        }
        if isVisual { motionSection }
        if isFootage { cropSection }
        if isVisual { opacitySection; transitionSection }
        if let ref = item.content.mediaRef {
            speedSection(ref)
            if ref.useAudio || track?.kind.hasAudio == true { audioSection(ref) }
        }
    }

    // MARK: Clip

    private var clipSection: some View {
        Section("Clip") {
            TextField("Name", text: Binding(get: { item.name }, set: { v in modify("Rename", key: "name") { $0.name = v } }))
            LabeledContent("Start") {
                SecondsField(value: item.start.seconds) { v in
                    guard let track else { return }
                    editor.perform(MoveItem(item.id, to: track.id, at: RationalTime(seconds: max(0, v)).roundedToFrame(rate)))
                }
            }
            LabeledContent("Duration") {
                SecondsField(value: item.range.duration.seconds) { v in
                    let end = item.start + RationalTime(seconds: max(rate.frameDuration.seconds, v)).roundedToFrame(rate)
                    editor.perform(TrimItem(item.id, edge: .end, to: end, ripple: editor.settings.editing.rippleByDefault))
                }
            }
            Toggle("Enabled", isOn: Binding(get: { item.enabled }, set: { v in modify(v ? "Enable" : "Disable") { $0.enabled = v } }))
                .help("A disabled clip stays on the timeline but isn't seen or heard (⇧E)")
            Toggle("Locked (kept when re-drafting)", isOn: Binding(get: { item.locked }, set: { v in modify(v ? "Lock" : "Unlock") { $0.locked = v } }))
            LabeledContent("Origin", value: item.origin.isAuto ? "Automatic draft" : "Added by you")
            HStack {
                Button("Split at Playhead") { editor.bladeAtPlayhead() }
                if case .media(let ref) = item.content, isVisual {
                    Button("Freeze Frame") { Task { await model.freezeFrame() } }.help("Insert a 2-second still of the frame at the playhead (⇧F)")
                    if ref.useAudio { Button("Detach Audio") { editor.run(.detachAudio) }.help("Move this clip's sound to its own audio track") }
                }
            }
            .controlSize(.small)
        }
    }

    // MARK: Motion

    @ViewBuilder private var motionSection: some View {
        Section {
            keyed("Position X", 0...1, name: "Move", key: "x", { $0.transform.position }, { $0.transform.position = $1 },
                  get: { $0.x }, set: { NormPoint($1, $0.y) })
            keyed("Position Y", 0...1, name: "Move", key: "y", { $0.transform.position }, { $0.transform.position = $1 },
                  get: { $0.y }, set: { NormPoint($0.x, $1) })
            keyed("Scale", 0.1...3, name: "Scale", key: "scale", { $0.transform.scale }, { $0.transform.scale = $1 })
            keyed("Rotation", -180...180, name: "Rotate", key: "rot", { $0.transform.rotation }, { $0.transform.rotation = $1 })
            if isFootage {
                keyed("Zoom", 1...4, name: "Zoom", key: "zoom", { $0.transform.zoom }, { $0.transform.zoom = $1 })
                Picker("Fit", selection: Binding(get: { item.transform.fit }, set: { v in modify("Fit") { $0.transform.fit = v } })) {
                    Text("Fill (crop to frame)").tag(FitMode.fill); Text("Fit (show all)").tag(FitMode.fit); Text("Stretch").tag(FitMode.stretch)
                }
                HStack {
                    Toggle("Flip horizontal", isOn: Binding(get: { item.transform.flipH }, set: { v in modify("Flip") { $0.transform.flipH = v } }))
                    Toggle("Flip vertical", isOn: Binding(get: { item.transform.flipV }, set: { v in modify("Flip") { $0.transform.flipV = v } }))
                }
            }
            if case .text = item.content {
                LabeledContent("Place") {
                    HStack(spacing: 4) {
                        ForEach([("Top", 0.13), ("Middle", 0.5), ("Lower third", 0.72), ("Bottom", 0.86)], id: \.0) { name, y in
                            Button(name) { modify("Move Text") { $0.transform.position = .constant(NormPoint(0.5, y)) } }
                        }
                    }
                    .controlSize(.small)
                }
            }
            Button("Reset Motion") {
                modify("Reset Motion") { t in
                    var fresh = Transform.fullFrame
                    fresh.box = t.transform.box; fresh.crop = t.transform.crop; fresh.fit = t.transform.fit
                    if case .text = t.content { fresh.position = t.transform.position }
                    t.transform = fresh
                }
            }
            .controlSize(.small)
        } header: {
            Text("Motion")
        } footer: {
            Text(local == nil ? "Move the playhead over this clip to add keyframes."
                              : "◆ adds a keyframe at the playhead. Once a property has keyframes, dragging its slider sets the value at the playhead.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Crop

    private var cropSection: some View {
        let c = item.transform.crop
        return Section("Crop") {
            cropSlider("Left", c.x) { v, r in NormRect(x: v, y: r.y, width: max(0.05, r.x + r.width - v), height: r.height) }
            cropSlider("Right", 1 - (c.x + c.width)) { v, r in NormRect(x: r.x, y: r.y, width: max(0.05, 1 - v - r.x), height: r.height) }
            cropSlider("Top", c.y) { v, r in NormRect(x: r.x, y: v, width: r.width, height: max(0.05, r.y + r.height - v)) }
            cropSlider("Bottom", 1 - (c.y + c.height)) { v, r in NormRect(x: r.x, y: r.y, width: r.width, height: max(0.05, 1 - v - r.y)) }
            if c != .full { Button("Reset Crop") { modify("Reset Crop") { $0.transform.crop = .full } }.controlSize(.small) }
        }
    }

    private func cropSlider(_ label: String, _ value: Double, _ apply: @escaping @Sendable (Double, NormRect) -> NormRect) -> some View {
        LabeledContent(label) {
            HStack {
                Slider(value: Binding(get: { value }, set: { v in modify("Crop", key: "crop-\(label)") { $0.transform.crop = apply(v, $0.transform.crop) } }),
                       in: 0...0.45) { e in if !e { editor.endGesture() } }
                Text("\(Int((value * 100).rounded()))%").font(.caption.monospacedDigit()).frame(width: 44, alignment: .trailing)
            }
        }
    }

    // MARK: Opacity, blend, transition

    private var opacitySection: some View {
        Section("Opacity") {
            keyed("Opacity", 0...1, name: "Opacity", key: "opacity", { $0.opacity }, { $0.opacity = $1 })
            Picker("Blend mode", selection: Binding(get: { item.blend }, set: { v in modify("Blend Mode") { $0.blend = v } })) {
                Text("Normal").tag(ClipperCore.BlendMode.normal); Text("Add").tag(ClipperCore.BlendMode.add)
                Text("Screen").tag(ClipperCore.BlendMode.screen); Text("Multiply").tag(ClipperCore.BlendMode.multiply)
            }
            slider("Fade in (s)", item.fadeIn.seconds, 0...3) { v in modify("Fade In", key: "fi") { $0.fadeIn = RationalTime(seconds: v) } }
            slider("Fade out (s)", item.fadeOut.seconds, 0...3) { v in modify("Fade Out", key: "fo") { $0.fadeOut = RationalTime(seconds: v) } }
        }
    }

    private var transitionSection: some View {
        Section {
            Picker("Transition in", selection: Binding(get: { item.transition?.kind }, set: { kind in
                modify("Transition") { item in
                    item.transition = kind.map { ClipperCore.Transition($0, duration: item.transition?.duration ?? RationalTime(seconds: 0.5)) }
                }
            })) {
                Text("None").tag(ClipperCore.Transition.Kind?.none)
                Text("Cross Dissolve").tag(ClipperCore.Transition.Kind?.some(.crossDissolve))
                Text("Dip to Black").tag(ClipperCore.Transition.Kind?.some(.dipToBlack))
                Text("Dip to White").tag(ClipperCore.Transition.Kind?.some(.dipToWhite))
            }
            if let t = item.transition {
                slider("Duration (s)", t.duration.seconds, 0.1...2) { v in
                    modify("Transition Duration", key: "td") { $0.transition?.duration = RationalTime(seconds: v) }
                }
            }
        } header: {
            Text("Transition")
        } footer: {
            Text("From the clip before this one on the same track (or from the background if there's a gap). ⇧D adds a cross dissolve.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Speed and audio

    private func speedSection(_ ref: MediaRef) -> some View {
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
        }
    }

    private func audioSection(_ ref: MediaRef) -> some View {
        Section("Audio") {
            Toggle("Clip audio", isOn: Binding(get: { ref.useAudio }, set: { v in
                modify(v ? "Unmute Clip" : "Mute Clip") { if case .media(var m) = $0.content { m.useAudio = v; $0.content = .media(m) } }
            }))
            if ref.useAudio {
                keyed("Volume (dB)", -40...12, name: "Volume", key: "gain", { $0.gain }, { $0.gain = $1 })
                if !isVisual {
                    slider("Fade in (s)", item.fadeIn.seconds, 0...3) { v in modify("Fade In", key: "fi") { $0.fadeIn = RationalTime(seconds: v) } }
                    slider("Fade out (s)", item.fadeOut.seconds, 0...3) { v in modify("Fade Out", key: "fo") { $0.fadeOut = RationalTime(seconds: v) } }
                }
            }
        }
    }

    /// Slider speeds snap to whole percentages (and exactly 100%) so the label and the clip agree.
    nonisolated static func niceSpeed(_ v: Double) -> Double {
        let pct = (v * 100).rounded()
        return abs(pct - 100) < 3 ? 1 : pct / 100
    }

    // MARK: Keyframed rows

    /// The playhead in item time, or nil when it isn't over the item (keyframes go where the playhead is).
    private var local: RationalTime? {
        let t = editor.playhead - item.start
        return t >= .zero && t <= item.range.duration ? t : nil
    }

    /// Keys within half a frame of the playhead count as "here". In seconds: `frameDuration * 0.5` would round back up to
    /// a whole frame at the rate's own timescale (1/30 × 0.5 → 1/30).
    private var halfFrame: RationalTime { RationalTime(seconds: rate.frameDuration.seconds / 2) }

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
                NumberField(value: value) { v in
                    modify(name) { item in
                        let p = read(item)
                        if p.isAnimated, let t { write(&item, p.setting(set(p.value(at: t), v), at: t, tolerance: half)) }
                        else { write(&item, .constant(set(p.value(at: .zero), v))) }
                    }
                }
            }
            .buttonStyle(.borderless)
        } label: { Text(label) }
    }

    private func slider(_ label: String, _ value: Double, _ range: ClosedRange<Double>, _ set: @escaping @MainActor (Double) -> Void) -> some View {
        LabeledContent(label) {
            HStack {
                Slider(value: Binding(get: { value }, set: set), in: range) { editing in if !editing { editor.endGesture() } }
                NumberField(value: value, set: set)
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

/// Editing several selected items at once.
struct MultiSelectionInspector: View {
    @Bindable var model: AppModel
    @Bindable var editor: EditorModel

    var body: some View {
        let items = editor.selectedItems
        Section("\(items.count) items selected") {
            Button("Enable All") { set("Enable") { $0.enabled = true } }
            Button("Disable All") { set("Disable") { $0.enabled = false } }
            Button("Add Cross Dissolve to Each") { editor.run(.addTransition) }
            Button("Remove Transitions") { set("Remove Transitions") { $0.transition = nil } }
            Button("Reset Motion") { set("Reset Motion") { t in let box = t.transform.box; t.transform = .fullFrame; t.transform.box = box } }
            Text("Colour changes in the Color tab apply to every selected clip.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func set(_ name: String, _ change: @escaping @Sendable (inout Item) -> Void) {
        editor.perform(Batch(editor.selectedItems.map { ModifyItem($0.id, name: "", change) }, name: name))
    }
}

struct StylePicker: View {
    @Bindable var editor: EditorModel
    let selection: String
    let set: (String) -> Void
    var body: some View {
        Picker("Style", selection: Binding(get: { selection }, set: set)) {
            ForEach(editor.timeline.styles.keys.sorted(), id: \.self) { Text($0).tag($0) }
        }
    }
}

/// A compact number field that commits on Return (sliders cover dragging).
struct NumberField: View {
    let value: Double
    let set: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .font(.caption.monospacedDigit())
            .multilineTextAlignment(.trailing)
            .frame(width: 52)
            .focused($focused)
            .onSubmit { if let v = Double(text.replacingOccurrences(of: ",", with: ".")) { set(v) } else { text = Self.format(value) } }
            .onAppear { text = Self.format(value) }
            .onChange(of: value) { if !focused { text = Self.format(value) } }
    }

    static func format(_ v: Double) -> String { String(format: abs(v) >= 100 ? "%.0f" : "%.2f", v) }
}

/// A text field for words that get re-split on every change (captions): what's typed is kept as typed while the field
/// has focus — a trailing space would otherwise vanish when the words are joined back — and refreshed from the model
/// otherwise (undo, edits elsewhere).
struct LiveTextField: View {
    let title: String
    let value: String
    let set: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text, axis: .vertical)
            .lineLimit(1...4)
            .focused($focused)
            .onAppear { text = value }
            .onChange(of: text) { if focused, text != value { set(text) } }
            .onChange(of: value) { if !focused { text = value } }
            .onChange(of: focused) { if !focused { text = value } }
    }
}

/// Seconds, committed on Return.
struct SecondsField: View {
    let value: Double
    let set: (Double) -> Void
    var body: some View {
        HStack(spacing: 4) {
            NumberField(value: value, set: set).frame(width: 70)
            Text("s").foregroundStyle(.secondary)
        }
    }
}
