import ClipperAutomation
import ClipperCore
import SwiftUI

// MARK: - Color

/// Lumetri-style basic correction for the selected clips (every selected clip and still gets the same change).
struct ColorInspector: View {
    @Bindable var editor: EditorModel

    /// Clips and stills on visual tracks.
    private func footage(_ items: [Item]) -> [Item] {
        items.filter { item in
            guard editor.timeline.tracks.first(where: { $0.items.contains { $0.id == item.id } })?.kind.isVisual == true else { return false }
            switch item.content { case .media, .image: return true; default: return false }
        }
    }

    var body: some View {
        let targets = footage(editor.selectedItems)
        if let first = targets.first {
            let c = first.color
            Section(targets.count == 1 ? "Looks — \(first.name)" : "Looks — \(targets.count) clips") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 6)], spacing: 6) {
                    Button("None") { set(targets, "Remove Look") { $0 = .none } }
                    ForEach(ColorAdjust.looks, id: \.name) { look in
                        Button(look.name) { set(targets, "Look: \(look.name)") { $0 = look.adjust } }
                            .tint(c == look.adjust ? .accentColor : nil)
                    }
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
            Section("Basic correction") {
                row("Exposure", c.exposure, -3...3, "exp", targets) { $0.exposure = $1 }
                row("Contrast", c.contrast, -1...1, "con", targets) { $0.contrast = $1 }
                row("Highlights", c.highlights, -1...1, "hi", targets) { $0.highlights = $1 }
                row("Shadows", c.shadows, -1...1, "sh", targets) { $0.shadows = $1 }
                row("Saturation", c.saturation, -1...1, "sat", targets) { $0.saturation = $1 }
                row("Temperature", c.temperature, -1...1, "temp", targets) { $0.temperature = $1 }
                row("Tint", c.tint, -1...1, "tint", targets) { $0.tint = $1 }
            }
            Section {
                Button("Reset") { set(targets, "Reset Colour") { $0 = .none } }.disabled(c.isNone)
                Button("Apply to All Clips") {
                    let all = footage(editor.timeline.allItems)
                    let look = c
                    set(all, "Apply Colour to All Clips") { $0 = look }
                }
                .help("Give every clip and still on the timeline this colour")
            } footer: {
                Text("Applied after HDR tone mapping, identically in the preview and the export.").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Section { Text("Select one or more clips to colour-correct them.").foregroundStyle(.secondary) }
        }
    }

    private func row(_ label: String, _ value: Double, _ range: ClosedRange<Double>, _ key: String, _ targets: [Item],
                     _ change: @escaping @Sendable (inout ColorAdjust, Double) -> Void) -> some View {
        LabeledContent(label) {
            HStack {
                Slider(value: Binding(get: { value }, set: { v in set(targets, label, coalesce: key) { change(&$0, v) } }), in: range) { e in
                    if !e { editor.endGesture() }
                }
                NumberField(value: value) { v in let c = min(max(v, range.lowerBound), range.upperBound); set(targets, label) { change(&$0, c) } }
                Button { set(targets, "Reset \(label)") { change(&$0, 0) } } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless).disabled(value == 0).help("Reset \(label)")
            }
        }
    }

    private func set(_ targets: [Item], _ name: String, coalesce: String? = nil, _ change: @escaping @Sendable (inout ColorAdjust) -> Void) {
        let ids = Set(targets.map(\.id))
        guard !ids.isEmpty else { return }
        editor.perform(ModifyTimeline(name: name, coalescingKey: coalesce.map { "color-\($0)-\(ids.map(\.uuidString).sorted().joined())" }) { t in
            for ti in t.tracks.indices where !t.tracks[ti].locked {
                for ii in t.tracks[ti].items.indices where ids.contains(t.tracks[ti].items[ii].id) {
                    change(&t.tracks[ti].items[ii].color)
                }
            }
        })
    }
}

// MARK: - Captions

/// Every caption in one place: one style for all of them, how many words each shows, and each caption's text.
struct CaptionsInspector: View {
    @Bindable var editor: EditorModel
    @State private var trackID: TrackID?

    private var tracks: [Track] { editor.timeline.tracks(of: .caption) }
    private var track: Track? { tracks.first { $0.id == trackID } ?? tracks.first { !$0.hidden } ?? tracks.first }

    /// The style most of the track's captions use.
    private func mainStyle(_ track: Track) -> String? {
        let styles = track.items.compactMap { item -> String? in if case .caption(let c) = item.content { c.style } else { nil } }
        return Dictionary(grouping: styles, by: { $0 }).max { $0.value.count < $1.value.count }?.key
    }

    var body: some View {
        if let track {
            if tracks.count > 1 {
                Section {
                    Picker("Caption track", selection: Binding(get: { track.id }, set: { trackID = $0 })) {
                        ForEach(tracks) { t in Text(t.name + (t.language.map { " (\($0))" } ?? "") + (t.hidden ? " — hidden" : "")).tag(t.id) }
                    }
                }
            }
            Section {
                Toggle("Show on the video", isOn: Binding(get: { !track.hidden }, set: { v in
                    editor.perform(ModifyTrack(track.id, name: v ? "Show Captions" : "Hide Captions") { $0.hidden = !v })
                }))
                Button("Add Caption at Playhead") { addCaption(to: track) }
            }
            if let key = mainStyle(track) {
                Section("Style of all captions") { StyleEditor(editor: editor, styleKey: key, target: .captions) }
                paging(track, key)
            }
            Section("Captions (\(track.items.count))") {
                ForEach(track.items) { item in captionRow(item) }
            }
        } else {
            Section {
                Text("This timeline has no captions.").foregroundStyle(.secondary)
                Button("Add Caption at Playhead") { addCaption(to: nil) }
            }
        }
    }

    private func paging(_ track: Track, _ key: String) -> some View {
        let style = editor.timeline.styles[key] ?? TextStyle()
        return Section {
            Stepper("Up to \(style.wordsPerPage) word\(style.wordsPerPage == 1 ? "" : "s") per caption", value: Binding(get: { style.wordsPerPage }, set: { v in
                editor.perform(ModifyTimeline(name: "Words per Caption") { $0.styles[key]?.wordsPerPage = v })
            }), in: 1...15)
            Stepper("Up to \(style.maxLines) line\(style.maxLines == 1 ? "" : "s")", value: Binding(get: { style.maxLines }, set: { v in
                editor.perform(ModifyTimeline(name: "Caption Lines") { $0.styles[key]?.maxLines = v })
            }), in: 1...4)
            Button("Re-split Captions") { resplit(track, key) }
                .help("Regroup the words on this track into captions of this size (word timing and your text edits are kept)")
        } header: {
            Text("Words per caption")
        } footer: {
            Text("Changing the count takes effect when you re-split.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func captionRow(_ item: Item) -> some View {
        guard case .caption(let c) = item.content else { return AnyView(EmptyView()) }
        let selected = editor.selection.contains(item.id)
        return AnyView(HStack(alignment: .firstTextBaseline) {
            Button(Timecode.string(item.start.seconds, rate: editor.timeline.canvas.frameRate)) {
                editor.selection = [item.id]
                editor.seek(to: item.start)
            }
            .buttonStyle(.borderless).font(.caption.monospacedDigit())
            .foregroundStyle(selected ? Color.accentColor : .secondary)
            LiveTextField(title: "", value: c.text) { v in
                editor.perform(ModifyItem(item.id, name: "Edit Caption", coalescingKey: "\(item.id)-caption") { item in
                    guard case .caption(var cap) = item.content else { return }
                    cap.words = ClipInspector.retime(cap.words, to: v.split(separator: " ").map(String.init))
                    item.content = .caption(cap)
                })
            }
            Button { editor.perform(DeleteItems([item.id], ripple: false)) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless).help("Delete this caption")
        })
    }

    private func resplit(_ track: Track, _ key: String) {
        guard let style = editor.timeline.styles[key] else { return }
        let pages = CaptionPaging.repage(track.items, styleName: key, style: style, rate: editor.timeline.canvas.frameRate,
                                         seed: track.id.uuidString)
        let id = track.id
        editor.perform(ModifyTimeline(name: "Re-split Captions") { t in
            guard let i = t.trackIndex(id) else { return }
            if t.tracks[i].locked { throw EditError.trackLocked(id) }
            t.tracks[i].items = pages
        })
    }

    /// A 2-second caption at the playhead on the caption track (made if there is none), ready to type into.
    private func addCaption(to track: Track?) {
        let rate = editor.timeline.canvas.frameRate
        let key = track.flatMap(mainStyle) ?? BuiltIns.captionStyles.first { editor.timeline.styles[$0] != nil } ?? "bold-pop"
        var prerequisites: [any EditCommand] = []
        if editor.timeline.styles[key] == nil, let s = BuiltIns.styles[key] { prerequisites.append(SetStyle(key, s)) }
        let d = RationalTime(seconds: 2).roundedToFrame(rate)
        var item = Item(name: "Caption", range: TimeRange(start: editor.playhead, duration: d),
                        content: .caption(CaptionContent(words: [.init(text: "Caption", start: .zero, end: d)], style: key)))
        item.transform.position = .constant((editor.timeline.styles[key] ?? BuiltIns.styles[key] ?? TextStyle()).position)
        if editor.perform(Batch(prerequisites + [PlaceItems([.init(item, track: track?.id, kinds: [.caption])], name: "Add Caption")], name: "Add Caption")) {
            editor.selection = [item.id]
        }
    }
}

// MARK: - Project

/// Sequence settings: the frame (orientation), loudness, markers and credits.
struct ProjectInspector: View {
    @Bindable var editor: EditorModel

    static let frames: [(String, String, Int, Int)] = [
        ("9:16", "Vertical — Shorts, Reels, TikTok", 1080, 1920), ("16:9", "Horizontal — YouTube", 1920, 1080),
        ("1:1", "Square", 1080, 1080), ("4:5", "Portrait — Instagram feed", 1080, 1350),
    ]

    var body: some View {
        let tl = editor.timeline
        Section("Timeline") {
            TextField("Name", text: Binding(get: { tl.name }, set: { v in
                editor.perform(ModifyTimeline(name: "Rename Timeline", coalescingKey: "timeline-name") { $0.name = v })
            }))
            LabeledContent("Duration", value: Timecode.string(tl.duration.seconds, rate: tl.canvas.frameRate))
            if let p = tl.provenance { LabeledContent("Template", value: "\(p.template), variation \(p.seed)") }
        }
        Section {
            ForEach(Self.frames, id: \.0) { name, detail, w, h in
                let current = tl.canvas.width == w && tl.canvas.height == h
                Button {
                    editor.perform(ChangeCanvas(Canvas(width: w, height: h, frameRate: tl.canvas.frameRate)))
                    editor.zoomRequest = .fit(UUID())
                } label: {
                    HStack {
                        Image(systemName: current ? "checkmark.circle.fill" : "circle").foregroundStyle(current ? Color.accentColor : .secondary)
                        Text(name).bold().frame(width: 40, alignment: .leading)
                        Text(detail).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(w)×\(h)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            Picker("Frame rate", selection: Binding(get: { tl.canvas.frameRate }, set: { r in
                editor.perform(ChangeCanvas(Canvas(width: tl.canvas.width, height: tl.canvas.height, frameRate: r)))
            })) {
                ForEach([FrameRate.fps24, .fps25, .fps30, .fps60], id: \.self) { Text("\($0.description) fps").tag($0) }
                if ![FrameRate.fps24, .fps25, .fps30, .fps60].contains(tl.canvas.frameRate) { Text("\(tl.canvas.frameRate.description) fps").tag(tl.canvas.frameRate) }
            }
        } header: {
            Text("Frame (orientation)")
        } footer: {
            Text("Clips re-fit the new shape (reframed clips keep following the speaker); titles and captions keep their place. Pick a matching preset when exporting.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Audio") {
            Picker("Loudness", selection: Binding(get: { tl.loudnessTarget }, set: { v in
                editor.perform(ModifyTimeline(name: "Loudness Target") { $0.loudnessTarget = v })
            })) {
                Text("−14 LUFS (YouTube, TikTok, Instagram)").tag(Double?.some(-14))
                Text("−16 LUFS (podcasts)").tag(Double?.some(-16))
                Text("−23 LUFS (broadcast)").tag(Double?.some(-23))
                Text("Off (as mixed)").tag(Double?.none)
            }
        }
        Section {
            ForEach(tl.markers) { m in
                HStack {
                    Button(Timecode.string(m.time.seconds, rate: tl.canvas.frameRate)) { editor.seek(to: m.time) }
                        .buttonStyle(.borderless).font(.caption.monospacedDigit())
                    TextField("", text: Binding(get: { m.name }, set: { v in
                        editor.perform(ModifyTimeline(name: "Rename Marker", coalescingKey: "marker-\(m.id)") { t in
                            if let i = t.markers.firstIndex(where: { $0.id == m.id }) { t.markers[i].name = v }
                        })
                    }))
                    Button { editor.perform(ModifyTimeline(name: "Delete Marker") { $0.markers.removeAll { $0.id == m.id } }) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            Button("Add Marker at Playhead") { editor.run(.addMarker) }
        } header: {
            Text("Markers (\(tl.markers.count))")
        } footer: {
            Text("M adds a marker, ⇧M / ⌥M jump to the next / previous one.").font(.caption).foregroundStyle(.secondary)
        }
        if !tl.attributions.isEmpty {
            Section("Credits (add to your description)") {
                ForEach(tl.attributions, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
            }
        }
    }
}
