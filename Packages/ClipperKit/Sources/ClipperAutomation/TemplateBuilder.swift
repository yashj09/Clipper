import ClipperCore
import Foundation

/// "Save as template": turns an edited timeline back into a reusable `Template`.
///
/// Layout (slots, their placement and fill), fixed elements (titles, branding), styles, captions/music settings come
/// from the timeline; behaviour rules the timeline can't show (silence-cut thresholds, max duration…) come from the
/// template it was drafted from, when known. Per-clip automation (punch-in zooms, reframe paths, declick ramps) is
/// stripped: the template re-generates it for new clips.
public enum TemplateBuilder {
    public struct Result: Sendable {
        public var template: Template
        public var notes: [String]
    }

    public static func make(from timeline: Timeline, id: String, name: String, basedOn: Template? = nil) -> Result {
        var notes: [String] = []
        let duration = timeline.duration
        let total = duration.seconds
        let tolerance = 0.1

        // MARK: Slots
        let mediaTracks = timeline.tracks.filter { t in t.kind.isVisual && t.items.contains { $0.content.mediaRef != nil } }
        func mediaSeconds(_ t: Track) -> Double { t.items.filter { $0.content.mediaRef != nil }.reduce(0) { $0 + $1.range.duration.seconds } }
        let basedPrimary = basedOn?.primarySlot?.id
        let primaryTrack = mediaTracks.first { t in basedPrimary != nil && t.items.contains { $0.slot == basedPrimary } }
            ?? mediaTracks.max { mediaSeconds($0) < mediaSeconds($1) }

        var slots: [Slot] = []
        var usedIDs = Set<String>()
        for track in mediaTracks {
            let items = track.items.filter { $0.content.mediaRef != nil }
            guard let first = items.first else { continue }
            let isPrimary = track.id == primaryTrack?.id
            // The track's slot when all its slotted items agree (manual clips without a slot don't count), else its name.
            let slotIDs = Set(items.compactMap(\.slot))
            var slotID = slotIDs.count == 1 ? slotIDs.first! : slug(track.name)
            while usedIDs.contains(slotID) { slotID += "-2" }
            usedIDs.insert(slotID)
            let based = basedOn?.slots.first { $0.id == slotID }

            // Placement without per-clip automation.
            var transform = first.transform
            transform.position = .constant(first.transform.position.value(at: .zero))
            transform.scale = .constant(first.transform.scale.value(at: .zero))
            transform.rotation = .constant(first.transform.rotation.value(at: .zero))
            transform.zoom = .constant(1)
            transform.focus = .constant(.center)

            let role: SlotRole = isPrimary ? .primary
                : track.kind == .overlay ? .broll
                : (transform.box == .full && isBelow(track, primaryTrack, in: timeline)) ? .background : .secondary
            let fill = isPrimary ? .sequence : inferFill(items, primary: primaryTrack, total: total, tolerance: tolerance)
            let reframe: ReframeMode = based?.reframe ?? (items.contains { $0.transform.focus.isAnimated } ? .face : .none)
            let useAudio = !track.muted && items.contains { $0.content.mediaRef?.useAudio == true }
            let audioGain = baseGain(of: first) + track.gain
            slots.append(Slot(id: slotID, name: track.name, role: role, fill: fill, transform: transform, reframe: reframe,
                              useAudio: useAudio, audioGain: audioGain, aloneTransform: based?.aloneTransform,
                              optional: based?.optional ?? !isPrimary))
        }
        if slots.isEmpty {
            notes.append("No media in the timeline: added an empty main slot")
            slots.append(Slot(id: "main", name: "Main", role: .primary))
        }

        // MARK: Elements (titles, branding, solids, images)
        var elements: [TemplateElement] = []
        var styleNames = Set<String>()
        let titleText = basedOn?.elements.compactMap { e -> String? in if case .text(let t) = e.content { t.text } else { nil } }
        for track in timeline.tracks where track.kind == .title || track.kind == .overlay {
            for item in track.items {
                var content = item.content
                switch content {
                case .media, .caption: continue
                case .text(var t):
                    styleNames.insert(t.style)
                    // Titles generated from `{title}` go back to the placeholder.
                    if case .auto(pass: "elements") = item.origin, titleText?.contains(where: { $0.contains("{title}") }) == true {
                        t.text = "{title}"
                        content = .text(t)
                    }
                default: break
                }
                let s = item.start.seconds, e = item.end.seconds
                let timing: TemplateElement.Timing
                if s <= tolerance && e >= total - tolerance { timing = .whole }
                else if s <= tolerance { timing = .opening(seconds: round2(e)) }
                else if e >= total - tolerance { timing = .closing(seconds: round2(e - s)) }
                else {
                    notes.append("“\(item.name.isEmpty ? "element" : item.name)” sits mid-timeline; saved as an opening element of the same length")
                    timing = .opening(seconds: round2(e - s))
                }
                var transform = item.transform
                transform.position = .constant(item.transform.position.value(at: .zero))
                elements.append(TemplateElement(id: item.name.isEmpty ? "element-\(elements.count + 1)" : slug(item.name), track: track.kind,
                                                content: content, transform: transform, timing: timing,
                                                fadeIn: round2(item.fadeIn.seconds), fadeOut: round2(item.fadeOut.seconds)))
            }
        }

        // MARK: Rules
        var rules = basedOn?.rules ?? Rules()
        let captionItems = timeline.tracks.filter { $0.kind == .caption && !$0.hidden }.flatMap(\.items)
        let captionStyles = captionItems.compactMap { i -> String? in if case .caption(let c) = i.content { c.style } else { nil } }
        if let style = mostCommon(captionStyles) {
            rules.captions = CaptionRule(style: style)
            styleNames.insert(style)
        } else if rules.captions != nil {
            rules.captions = nil
            notes.append("No visible captions: captions are off in the template")
        }
        let musicItems = timeline.tracks.filter { $0.kind == .music && !$0.muted }.flatMap(\.items)
        let ducked = musicItems.contains { $0.gain.isAnimated }
        if ducked, rules.duck == nil { rules.duck = DuckRule() }
        if !ducked, musicItems.isEmpty == false, rules.duck != nil, !(timeline.tracks.contains { $0.kind == .caption }) { rules.duck = nil }
        if let primaryItems = primaryTrack?.items, primaryItems.contains(where: { $0.transform.zoom.value(at: .zero) > 1.001 }),
           rules.punchIn == nil {
            rules.punchIn = PunchInRule()
        }
        rules.loudnessTarget = timeline.loudnessTarget

        // MARK: Music
        var music = basedOn?.music ?? MusicPolicy()
        if let m = musicItems.first {
            music.enabled = true
            music.gain = round2(m.gain.keys.map(\.value).max() ?? m.gain.value(at: .zero))
            music.fadeIn = round2(m.fadeIn.seconds)
            music.fadeOut = round2((musicItems.last ?? m).fadeOut.seconds)
        } else {
            music.enabled = false
        }

        // MARK: Styles and the rest
        var styles: [String: TextStyle] = [:]
        for n in styleNames { if let s = timeline.styles[n] { styles[n] = s } }
        let preset = basedOn?.exportPreset ?? defaultPreset(for: timeline.canvas)
        let template = Template(id: id, version: 1, name: name,
                                summary: "Saved from “\(timeline.name)”" + (basedOn.map { ", based on \($0.name)" } ?? ""),
                                contentType: basedOn?.contentType ?? .custom, canvas: timeline.canvas, slots: slots,
                                elements: elements, rules: rules, styles: styles, music: music, exportPreset: preset)
        notes += TemplateValidator.validate(template).map { "Check: \($0)" }
        return Result(template: template, notes: notes)
    }

    // MARK: Helpers

    static func inferFill(_ items: [Item], primary: Track?, total: Double, tolerance: Double) -> SlotFill {
        if let primary {
            let p = primary.items.filter { $0.content.mediaRef != nil }
            let mirrors = items.count == p.count && zip(items, p).allSatisfy { a, b in
                a.range == b.range && a.content.mediaRef?.source.start == b.content.mediaRef?.source.start
            }
            if mirrors && !items.isEmpty { return .linked }
        }
        let assets = Set(items.compactMap { $0.content.mediaRef?.asset })
        let covers = (items.first?.start.seconds ?? 1) <= tolerance && (items.last?.end.seconds ?? 0) >= total - tolerance
        if assets.count == 1 && covers { return items.count == 1 ? .single : .loop }
        return .sequence
    }

    static func baseGain(of item: Item) -> Double {
        // Draft items carry declick ramps (base−40 → base → base−40); the base level is the maximum.
        round2(item.gain.keys.map(\.value).max() ?? item.gain.value(at: .zero))
    }

    static func isBelow(_ track: Track, _ other: Track?, in timeline: Timeline) -> Bool {
        guard let other, let a = timeline.trackIndex(track.id), let b = timeline.trackIndex(other.id) else { return false }
        return a < b
    }

    static func mostCommon(_ values: [String]) -> String? {
        Dictionary(grouping: values, by: { $0 }).max { ($0.value.count, $1.key) < ($1.value.count, $0.key) }?.key
    }

    static func defaultPreset(for canvas: Canvas) -> String {
        let a = canvas.aspect
        if a < 0.7 { return "shorts-1080x1920" }
        if a < 0.9 { return "portrait-4x5" }
        if a < 1.2 { return "square-1080" }
        return "youtube-1080p"
    }

    public static func slug(_ s: String) -> String {
        let lowered = s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(lowered).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "template" : collapsed
    }

    static func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }
}

/// Checks a template for problems a hand-edited JSON file can introduce.
public enum TemplateValidator {
    public static func validate(_ t: Template) -> [String] {
        var issues: [String] = []
        if t.id.isEmpty || t.id != TemplateBuilder.slug(t.id) { issues.append("id “\(t.id)” should be lowercase letters, digits and dashes") }
        if t.canvas.width < 16 || t.canvas.height < 16 || t.canvas.width % 2 == 1 || t.canvas.height % 2 == 1 {
            issues.append("canvas \(t.canvas.width)×\(t.canvas.height) must be even and at least 16 px")
        }
        if t.canvas.frameRate.fps < 1 || t.canvas.frameRate.fps > 240 { issues.append("frame rate \(t.canvas.frameRate) is out of range") }
        let primaries = t.slots.filter { $0.role == .primary }
        if primaries.count != 1 { issues.append("needs exactly one primary slot (has \(primaries.count))") }
        let ids = t.slots.map(\.id)
        if Set(ids).count != ids.count { issues.append("slot ids must be unique") }
        if t.slots.contains(where: { $0.fill == .linked }) && primaries.isEmpty { issues.append("a linked slot needs a primary slot to follow") }
        for s in t.slots where s.transform.box.width <= 0 || s.transform.box.height <= 0 {
            issues.append("slot “\(s.id)” has an empty box")
        }
        let known = Set(t.styles.keys).union(BuiltIns.styles.keys)
        if let c = t.rules.captions, !known.contains(c.style) { issues.append("caption style “\(c.style)” is not defined") }
        for e in t.elements {
            if case .text(let text) = e.content, !known.contains(text.style) { issues.append("element “\(e.id)” uses undefined style “\(text.style)”") }
        }
        if let m = t.rules.maxDuration, m <= 0 { issues.append("maxDuration must be positive") }
        if let s = t.rules.silenceCut, s.minGap <= 0 || s.padBefore < 0 || s.padAfter < 0 { issues.append("silenceCut values must be positive") }
        if let b = t.rules.beatCut, b.everyBeats < 1 { issues.append("beatCut.everyBeats must be ≥ 1") }
        if ExportPreset.named(t.exportPreset) == nil { issues.append("unknown export preset “\(t.exportPreset)”") }
        for m in t.music.moods where !Mood.canonical.contains(m) { issues.append("music mood “\(m)” isn't one of: \(Mood.canonical.joined(separator: ", "))") }
        return issues
    }

    /// Decodes template JSON with readable errors ("slots[0].fill: unknown value 'loops'").
    public static func decode(_ data: Data) -> (Template?, [String]) {
        do {
            let t = try ClipperJSON.decode(Template.self, from: data)
            return (t, validate(t))
        } catch let DecodingError.keyNotFound(key, ctx) {
            return (nil, ["\(path(ctx.codingPath + [key])): missing"])
        } catch let DecodingError.typeMismatch(type, ctx) {
            return (nil, ["\(path(ctx.codingPath)): expected \(type)"])
        } catch let DecodingError.valueNotFound(type, ctx) {
            return (nil, ["\(path(ctx.codingPath)): expected \(type), found null"])
        } catch let DecodingError.dataCorrupted(ctx) {
            return (nil, ["\(path(ctx.codingPath)): \(ctx.debugDescription)"])
        } catch {
            return (nil, ["\(error)"])
        }
    }

    static func path(_ keys: [CodingKey]) -> String {
        let p = keys.map { k in k.intValue.map { "[\($0)]" } ?? ".\(k.stringValue)" }.joined()
        return p.hasPrefix(".") ? String(p.dropFirst()) : (p.isEmpty ? "(root)" : p)
    }
}
