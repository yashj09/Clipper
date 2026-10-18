import ClipperCore
import Foundation

/// Turns clips + analysis + a template into an editable timeline. Pure and deterministic: the same input (including
/// `settings.seed`) always yields a byte-identical timeline, so the CLI and the app produce the same draft.
public enum DraftPipeline {
    public static func run(_ input: DraftInput) -> DraftResult {
        var report = DraftReport()
        let template = input.template
        let rules = template.rules
        let rate = template.canvas.frameRate
        var ids = IDGenerator(seed: input.settings.seed ^ stableHash(template.id))
        var styles = BuiltIns.styles
        for (k, v) in template.styles { styles[k] = v }

        var timeline = Timeline(id: ids.uuid(), name: input.settings.name, canvas: template.canvas, styles: styles,
                                loudnessTarget: rules.loudnessTarget)
        guard let primary = template.primarySlot else {
            report.warnings.append("Template '\(template.id)' has no primary slot")
            return DraftResult(timeline: timeline, report: report, addedAssets: [])
        }
        let byslot = Dictionary(grouping: input.clips.indices, by: { input.clips[$0].slot ?? primary.id })
        let primaryClips = (byslot[primary.id] ?? []).map { input.clips[$0] }
        let maxDuration = input.settings.maxDuration ?? rules.maxDuration
        let wantsMusic = (input.settings.music ?? template.music.enabled) && !input.music.isEmpty
        if (input.settings.music ?? template.music.enabled) && input.music.isEmpty {
            report.warnings.append("No music in the library; add tracks or a music folder to get automatic music")
        }

        // 1. Cut the primary storyline into segments.
        var segments: [Segment] = []
        var plans: [Int: SpeechPlan] = [:]
        var music: MusicTrack?
        var musicOffset = 0.0
        if let beatRule = rules.beatCut {
            let total = primaryClips.reduce(0) { $0 + $1.range.upperBound - $1.range.lowerBound }
            let target = min(maxDuration ?? 30, total)
            if wantsMusic {
                music = Music.pick(input.music, policy: template.music, target: target, wantEnergy: 0.7,
                                   forced: input.settings.musicID, seed: input.settings.seed)
            }
            if let m = music, m.beats != nil {
                musicOffset = Music.startOffset(m, alignToBeat: true)
                let beats = Music.timelineBeats(m, offset: musicOffset, until: target)
                segments = Cutting.beatCut(clips: primaryClips, beats: beats, target: target, rule: beatRule)
                    .map { var s = $0; s.clip = clipIndex(primaryClips, s.clip, in: input); return s }
                report.notes.append(String(format: "Cut %d clips on the beat (%.0f BPM, every %d beats)",
                                           segments.count, m.bpm ?? m.beats?.bpm ?? 0, beatRule.everyBeats))
            } else {
                // No beat grid: even 2-second cuts.
                let beats = stride(from: 0.0, through: target, by: 0.5).map { $0 }
                segments = Cutting.beatCut(clips: primaryClips, beats: beats, target: target, rule: BeatCutRule(everyBeats: 4, tolerance: 0, minClip: 0.5))
                    .map { var s = $0; s.clip = clipIndex(primaryClips, s.clip, in: input); return s }
                report.warnings.append("No analysed music: used even 2 s cuts instead of beat cuts")
            }
        } else {
            for (i, clip) in input.clips.enumerated() where (clip.slot ?? primary.id) == primary.id {
                let plan = SpeechPlan(clip: clip, rule: rules.speechEdits)
                plans[i] = plan
                report.removedTakes += plan.removedTakes
                report.removedRestarts += plan.removedRestarts
                segments += Cutting.segments(for: i, clip: clip, rule: rules.silenceCut, plan: plan)
            }
            if let note = report.speechEditNote { report.notes.append(note) }
            let before = primaryClips.reduce(0) { $0 + $1.range.upperBound - $1.range.lowerBound }
            if let maxSilent = rules.maxSilentClip { segments = Cutting.trimSilent(segments, maxLength: maxSilent) }
            let after = segments.reduce(0) { $0 + $1.duration }
            if rules.silenceCut != nil, before - after > 0.05 {
                report.removedSeconds = before - after
                let edits = plans.values.reduce(0.0) { $0 + $1.excluded.ranges.reduce(0) { $0 + $1.upperBound - $1.lowerBound } }
                if before - after - edits > 0.05 {
                    report.notes.append(String(format: "Removed %.1fs of pauses and fillers (%d segments kept)", before - after - edits, segments.count))
                }
            }
            if let maxDuration { segments = Cutting.fit(segments, maxDuration: maxDuration, report: &report) }
            if wantsMusic, let snapRule = rules.beatSnap {
                let total = segments.reduce(0) { $0 + $1.duration }
                music = Music.pick(input.music, policy: template.music, target: total, wantEnergy: nil,
                                   forced: input.settings.musicID, seed: input.settings.seed)
                if let m = music, m.beats != nil {
                    musicOffset = Music.startOffset(m, alignToBeat: true)
                    let beats = Music.timelineBeats(m, offset: musicOffset, until: total + snapRule.tolerance)
                    let snap = Cutting.beatSnap(segments, beats: beats, rule: snapRule, clips: input.clips)
                    segments = snap.segments
                    if snap.moved > 0 {
                        report.notes.append(String(format: "Snapped %d of %d cuts to the beat", snap.moved, segments.count))
                    }
                }
            }
        }

        // 2. Lay out slots as tracks.
        let visualSlotsWithClips = template.slots.filter { s in s.role != .logo && !(byslot[s.id] ?? []).isEmpty }
        let alone = visualSlotsWithClips.count == 1
        var primaryItems: [Item] = []
        var primaryTrackIndex: Int?
        var cursor = RationalTime.zero
        var segmentOf: [ItemID: Segment] = [:]
        for seg in segments {
            let clip = input.clips[seg.clip]
            let start = cursor
            let end = RationalTime.frames(start.seconds + seg.duration, rate)
            guard end > start else { continue }
            let range = TimeRange(start: start, end: end)
            var item = Item(id: ids.uuid(), name: clip.asset.name, range: range,
                            content: .media(MediaRef(asset: clip.asset.id, source: TimeRange(start: RationalTime(seconds: seg.start), duration: range.duration),
                                                     useAudio: primary.useAudio)),
                            transform: (alone ? primary.aloneTransform : nil) ?? primary.transform,
                            gain: declick(range.duration, base: primary.audioGain), origin: .auto(pass: "layout"), slot: primary.id)
            item.content = clampSource(item.content, to: clip.asset.info.duration)
            segmentOf[item.id] = seg
            primaryItems.append(item)
            cursor = end
        }
        let duration = cursor
        if duration == .zero { report.warnings.append("Nothing to place: add clips to the '\(primary.name)' slot") }

        for slot in template.slots {
            let kind: TrackKind = slot.role == .broll || slot.role == .logo ? .overlay : .video
            if slot.id == primary.id {
                primaryTrackIndex = timeline.tracks.count
                timeline.tracks.append(Track(id: ids.uuid(), kind: kind, name: slot.name, items: primaryItems))
                continue
            }
            let clips = (byslot[slot.id] ?? []).map { input.clips[$0] }
            if clips.isEmpty {
                if !slot.optional { report.warnings.append("Slot '\(slot.name)' has no clips") }
                continue
            }
            let transform = (alone ? slot.aloneTransform : nil) ?? slot.transform
            var items: [Item] = []
            func add(_ clip: ClipInput, at start: RationalTime, source: Double, length: Double) {
                let end = RationalTime.frames(start.seconds + length, rate)
                guard end > start else { return }
                let range = TimeRange(start: start, end: end)
                var item = Item(id: ids.uuid(), name: clip.asset.name, range: range,
                                content: .media(MediaRef(asset: clip.asset.id, source: TimeRange(start: RationalTime(seconds: source), duration: range.duration),
                                                         useAudio: slot.useAudio)),
                                transform: transform, gain: declick(range.duration, base: slot.audioGain), origin: .auto(pass: "layout"), slot: slot.id)
                item.content = clampSource(item.content, to: clip.asset.info.duration)
                items.append(item)
            }
            switch slot.fill {
            case .linked:
                let clip = clips[0]
                for p in primaryItems {
                    guard let ref = p.content.mediaRef else { continue }
                    let src = ref.source.start.seconds
                    guard src < clip.range.upperBound else { continue }
                    add(clip, at: p.start, source: src, length: min(p.range.duration.seconds, clip.range.upperBound - src))
                }
            case .loop:
                let clip = clips[0]
                var t = 0.0
                let len = clip.range.upperBound - clip.range.lowerBound
                while len > 0.1, t < duration.seconds - 0.01 {
                    let piece = min(len, duration.seconds - t)
                    add(clip, at: RationalTime.frames(t, rate), source: clip.range.lowerBound, length: piece)
                    t += piece
                }
            case .single:
                let clip = clips[0]
                add(clip, at: .zero, source: clip.range.lowerBound, length: min(clip.range.upperBound - clip.range.lowerBound, duration.seconds))
            case .sequence:
                var t = 0.0
                for clip in clips where t < duration.seconds - 0.01 {
                    let piece = min(clip.range.upperBound - clip.range.lowerBound, duration.seconds - t)
                    add(clip, at: RationalTime.frames(t, rate), source: clip.range.lowerBound, length: piece)
                    t += piece
                }
            }
            if slot.reframe != .none {
                items = items.map { item in reframed(item, input: input, slot: slot, transform: transform, canvas: template.canvas) }
            }
            timeline.tracks.append(Track(id: ids.uuid(), kind: kind, name: slot.name, items: items))
        }

        // 3. Spoken words on the timeline (zooms, captions, ducking), then the primary-track visual passes.
        let spoken = Speech.timedWords(primaryItems, segments: segmentOf)
        if let pti = primaryTrackIndex {
            var items = timeline.tracks[pti].items
            if primary.reframe != .none {
                items = items.map { reframed($0, input: input, slot: primary, transform: $0.transform, canvas: template.canvas) }
            }
            if let rule = rules.punchIn {
                let z = Visual.zooms(items, words: spoken, rule: rule)
                items = z.items
                if let note = z.note { report.notes.append(note) }
            }
            timeline.tracks[pti].items = items
        }

        // 4. Captions.
        let captionsOn = input.settings.captions ?? (rules.captions != nil)
        if captionsOn, let rule = rules.captions {
            if let style = styles[rule.style] {
                let caps = Captions.items(words: spoken, styleName: rule.style, style: style, rate: rate, ids: &ids)
                if !caps.isEmpty {
                    // Tag the captions with the transcript's language so they export as `<name>.<lang>.srt` too
                    // and translations know their source language.
                    let language = primaryClips.lazy.compactMap(\.analysis.transcript?.locale).first { !$0.isEmpty }
                        .map { Locale.Language(identifier: $0).minimalIdentifier }
                    timeline.tracks.append(Track(id: ids.uuid(), kind: .caption, name: "Captions", items: caps, language: language))
                    report.notes.append("Captioned \(spoken.filter { !$0.isFiller }.count) words in \(caps.count) pages (\(rule.style))")
                } else if !primaryClips.isEmpty {
                    report.warnings.append("No transcript available: captions skipped")
                }
            } else {
                report.warnings.append("Unknown caption style '\(rule.style)'")
            }
        }

        // 5. Music.
        var added: [MediaAsset] = []
        if wantsMusic, duration > .zero {
            if music == nil {
                music = Music.pick(input.music, policy: template.music, target: duration.seconds, wantEnergy: nil,
                                   forced: input.settings.musicID, seed: input.settings.seed)
                if let m = music { musicOffset = Music.startOffset(m, alignToBeat: m.beats != nil) }
            }
            if let m = music {
                let asset = musicAsset(m)
                added.append(asset)
                var items = Music.items(m, assetID: asset.id, offset: musicOffset, duration: duration.seconds,
                                        policy: template.music, rate: rate, ids: &ids)
                if let duck = rules.duck, !spoken.isEmpty {
                    items = Music.duck(items, speech: speechSpans(spoken), rule: duck, baseGain: template.music.gain)
                }
                timeline.tracks.append(Track(id: ids.uuid(), kind: .music, name: "Music", items: items))
                if let credit = m.license.attribution { timeline.attributions.append(credit) }
                report.musicTrack = m.title
                report.notes.append("Music: \(m.title) by \(m.artist)" + (m.bpm.map { String(format: " (%.0f BPM)", $0) } ?? ""))
            }
        }

        // 6. Template elements (titles, branding).
        for element in template.elements {
            var content = element.content
            if case .text(var t) = content, t.text.contains("{title}") {
                guard let title = input.settings.title, !title.isEmpty else { continue }
                t.text = t.text.replacingOccurrences(of: "{title}", with: title)
                content = .text(t)
            }
            let total = duration.seconds
            let (s, e): (Double, Double) = switch element.timing {
            case .whole: (0, total)
            case .opening(let secs): (0, min(secs, total))
            case .closing(let secs): (max(0, total - secs), total)
            }
            let start = RationalTime.frames(s, rate), end = RationalTime.frames(e, rate)
            guard end > start else { continue }
            var item = Item(id: ids.uuid(), name: element.id, range: TimeRange(start: start, end: end), content: content,
                            transform: element.transform, fadeIn: RationalTime.frames(element.fadeIn, rate),
                            fadeOut: RationalTime.frames(element.fadeOut, rate), origin: .auto(pass: "elements"))
            if case .text(let t) = content, let style = styles[t.style], element.transform == .fullFrame {
                item.transform.position = .constant(style.position)
            }
            timeline.tracks.append(Track(id: ids.uuid(), kind: element.track, name: element.id.capitalized, items: [item]))
        }

        // Drawn last so no earlier ID depends on how many retakes there were.
        timeline.markers = Speech.takeMarkers(plans, clips: input.clips, items: primaryItems, rate: rate, ids: &ids)

        // Captions above titles above everything else; audio-only tracks last.
        timeline.tracks = timeline.tracks.enumerated().sorted { a, b in
            let order: (TrackKind) -> Int = { [.video: 0, .overlay: 1, .title: 2, .caption: 3, .audio: 4, .music: 5][$0] ?? 9 }
            return (order(a.element.kind), a.offset) < (order(b.element.kind), b.offset)
        }.map(\.element)

        timeline.provenance = Provenance(template: template.id, templateVersion: template.version, seed: input.settings.seed,
                                         passes: ["cut", "layout", "visual", "captions", "music", "elements"],
                                         inputs: input.record)
        var durations = Dictionary(uniqueKeysWithValues: input.clips.map { ($0.asset.id, $0.asset.info.duration) })
        for a in added { durations[a.id] = a.info.duration }
        for issue in timeline.validate(assetDurations: durations) where issue.severity == .error {
            report.warnings.append("Internal: \(issue.message)")
        }
        return DraftResult(timeline: timeline, report: report, addedAssets: added)
    }

    /// The analyses a template's rules and slots read. The CLI and the app both request exactly these.
    public static func analysisKinds(for template: Template) -> Set<AnalysisKind> {
        var kinds: Set<AnalysisKind> = []
        let rules = template.rules
        if rules.speechEdits != nil || rules.silenceCut != nil || rules.captions != nil || rules.duck != nil {
            kinds.formUnion([.speech, .transcript])
        }
        if template.slots.contains(where: { $0.reframe == .face }) { kinds.insert(.faces) }
        if template.slots.contains(where: { $0.reframe == .saliency }) { kinds.insert(.visual) }
        return kinds
    }

    // MARK: Helpers

    /// Maps an index into `primaryClips` back to an index into `input.clips`.
    static func clipIndex(_ primaryClips: [ClipInput], _ i: Int, in input: DraftInput) -> Int {
        let id = primaryClips[i].asset.id
        return input.clips.firstIndex { $0.asset.id == id && $0.slot == primaryClips[i].slot } ?? i
    }

    /// 10 ms gain ramps at both ends of every cut so speech edits never click.
    static func declick(_ d: RationalTime, base: Double) -> Param<Double> {
        let ramp = RationalTime(value: 1, scale: 100)
        guard d > ramp + ramp else { return .constant(base) }
        return .keyframes([Keyframe(.zero, base - 40, .linear), Keyframe(ramp, base, .linear),
                           Keyframe(d - ramp, base, .linear), Keyframe(d, base - 40, .linear)])
    }

    /// Guards against float rounding pushing a source range a hair past the end of the media.
    static func clampSource(_ content: ItemContent, to mediaDuration: RationalTime) -> ItemContent {
        guard case .media(var ref) = content, ref.source.end > mediaDuration else { return content }
        ref.source.start = RationalTime.max(.zero, mediaDuration - ref.source.duration)
        return .media(ref)
    }

    /// Reframes a cropped item to follow the speaker's face, or the visually salient region when there are no faces
    /// (or the slot asks for saliency, e.g. gameplay and montage footage).
    static func reframed(_ item: Item, input: DraftInput, slot: Slot, transform: Transform, canvas: Canvas) -> Item {
        guard slot.reframe != .none, case .media(let ref) = item.content,
              let clip = input.clips.first(where: { $0.asset.id == ref.asset }) else { return item }
        var track: FaceTrack?
        if slot.reframe == .face, let faces = clip.analysis.faces, !faces.samples.isEmpty { track = faces }
        if track == nil, let visual = clip.analysis.visual {
            let samples = visual.samples.compactMap { s in s.salient.map { FaceSample(time: s.time, rect: $0, confidence: 1) } }
            if !samples.isEmpty { track = FaceTrack(samples: samples) }
        }
        guard let track else { return item }
        let boxAspect = (transform.box.width * Double(canvas.width)) / (transform.box.height * Double(canvas.height))
        return Visual.reframe(item, faces: track, sourceAspect: clip.asset.info.displayAspect, boxAspect: boxAspect)
    }

    static func speechSpans(_ words: [TimedWord]) -> [(Double, Double)] {
        var spans: [(Double, Double)] = []
        for w in words.sorted(by: { $0.start < $1.start }) {
            if let last = spans.last, w.start - last.1 < 0.5 { spans[spans.count - 1].1 = max(last.1, w.end) } else { spans.append((w.start, w.end)) }
        }
        return spans
    }

    /// A media asset for a music track, with a stable ID derived from the track's ID.
    public static func musicAsset(_ t: MusicTrack) -> MediaAsset {
        var g = IDGenerator(seed: stableHash("music|\(t.id)"))
        return MediaAsset(id: g.uuid(), key: AssetKey("music-\(t.id)"), name: t.title, url: t.url,
                          info: MediaInfo(kind: .audio, duration: RationalTime(seconds: t.duration), audioChannels: 2, audioSampleRate: 44_100),
                          tags: ["music"])
    }
}
