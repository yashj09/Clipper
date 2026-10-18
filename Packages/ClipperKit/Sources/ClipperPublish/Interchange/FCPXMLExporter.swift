import ClipperCore
import Foundation

/// Exports a Clipper timeline as a single-file FCPXML document (`.fcpxml`) for Final Cut Pro and DaVinci Resolve.
///
/// ## Version
/// Defaults to **FCPXML 1.11** (Final Cut Pro 10.6.6+; DaVinci Resolve 18.6+ imports it). Everything emitted here is
/// identical in the 1.10 and 1.11 DTDs (1.11 only *adds* elements we don't use), so `.v1_10` changes nothing but the
/// version attribute — use it for older Resolve releases, whose scripting API lists FCPXML 1.10 as its newest export.
///
/// ## Structure
/// `resources` (sequence `format`, one `format` per distinct source format, one `asset` per used media file, the Basic
/// Title `effect` when titles are emitted) → `library/event/project/sequence/spine`.
/// - **Primary storyline**: the `.video` track with the most media time (or `primaryTrack`). Holes become `<gap>`s,
///   and a trailing gap extends the spine to the timeline's end so every connected clip has a parent.
/// - **Connected clips**: every other track's items anchor to the spine element covering their start. Visual tracks
///   above the primary get lanes 1, 2, … (bottom to top), visual tracks below it −1, −2, …, and audio/music tracks
///   continue the negative lanes. Anchored `offset`s are in the parent's local time (`parent.start + (t − parent.offset)`).
/// - **Markers**: each timeline marker → `<marker>` (one frame, `value` = its name) on the spine element under it, in
///   that element's local time like an anchored offset.
/// - **Times** are exact rationals on the sequence frame grid (`"1001/30000s"`, `"45/30s"`, `"3s"`): item edges are
///   rounded to whole frames once, so spine offsets are contiguous by construction. Source `start`s sit on the asset's
///   own grid (video: its nominal rate, audio: its sample rate).
/// - **Speed ≠ 1** → `<timeMap>` (linear `timept`s mapping retimed local time → source time); the clip's `start` is
///   in the retimed domain, as FCP requires.
/// - **Transforms** → `adjust-crop mode="trim"` + `adjust-transform` (see `FCPGeometry` for the coordinate math),
///   keyframed via `<param name="position|scale|rotation"><keyframeAnimation>`.
/// - **Opacity** → `adjust-blend amount`, **gain** (item + track, dB) → `adjust-volume amount="-12dB"`, both with
///   keyframes (ducking) and `fadeIn`/`fadeOut` (Clipper fades are linear on opacity and volume).
/// - **Text** → `<title>` using Final Cut's Basic Title with `text`/`text-style-def`.
/// - **Captions** → native FCP `<caption role="iTT?captionFormat=ITT.<lang>">` (default) so they land in FCP's caption
///   lane per language and export as iTT/SRT from FCP; or Basic Titles (`.titles`, burned-in look, better for
///   Resolve which doesn't map FCPXML captions to subtitle tracks reliably); or omitted. For Resolve, pair with the
///   SRT sidecar (`captionsSRT`).
public struct FCPXMLExporter: TimelineInterchangeExporter {
    public static let fileExtension = "fcpxml"

    public enum Version: String, Sendable, CaseIterable {
        case v1_10 = "1.10"
        case v1_11 = "1.11"
    }

    public enum CaptionMode: String, Sendable, CaseIterable {
        /// FCP closed captions (`<caption>`, iTT role per language).
        case captions
        /// Basic Title clips, one per caption page.
        case titles
        /// Leave captions out (use the SRT sidecar instead).
        case omit
    }

    /// Effect UID Final Cut Pro uses for its built-in Basic Title.
    public static let basicTitleUID =
        ".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti"

    public var version: Version
    /// Project name in FCP; defaults to the timeline's name.
    public var projectName: String?
    public var eventName: String
    public var captionMode: CaptionMode
    /// Track to use as the primary storyline instead of the automatic choice.
    public var primaryTrack: TrackID?

    public init(version: Version = .v1_11, projectName: String? = nil, eventName: String = "Clipper",
                captionMode: CaptionMode = .captions, primaryTrack: TrackID? = nil) {
        self.version = version; self.projectName = projectName; self.eventName = eventName
        self.captionMode = captionMode; self.primaryTrack = primaryTrack
    }

    public func export(_ timeline: Timeline, assets: [AssetID: MediaAsset]) throws -> Data {
        var builder = try FCPXMLBuilder(options: self, timeline: timeline, assets: assets)
        return builder.build()
    }

    /// Same as `export`, naming the FCP project.
    public func exportFCPXML(_ timeline: Timeline, assets: [AssetID: MediaAsset], projectName: String) throws -> Data {
        var copy = self
        copy.projectName = projectName
        return try copy.export(timeline, assets: assets)
    }

    /// The visible captions as an SRT sidecar, to ship next to the `.fcpxml` (Resolve imports SRT as a subtitle track).
    public static func captionsSRT(_ timeline: Timeline) -> String { Subtitles.srt(timeline) }
}

// MARK: - Builder

private struct FCPXMLBuilder {
    /// A spine element and the frame span it occupies on the sequence.
    struct Node {
        let element: XMLElement
        let offset: Int64
        let duration: Int64
        /// The element's local time at its first frame (its `start`).
        let localStart: RationalTime
        var anchored: [(offset: RationalTime, lane: Int, element: XMLElement)] = []
        var markers: [XMLElement] = []
    }

    let options: FCPXMLExporter
    let timeline: Timeline
    let assets: [AssetID: MediaAsset]
    let used: [MediaAsset]
    let grid: FrameGrid
    let frame: FCPGeometry.Frame

    var nextID = 1
    var formats: [XMLElement] = []
    var formatIDs: [String: String] = [:]
    var assetElements: [XMLElement] = []
    var assetIDs: [AssetID: String] = [:]
    var titleEffectID: String?
    var styleCount = 0
    let sequenceFormatID: String

    init(options: FCPXMLExporter, timeline: Timeline, assets: [AssetID: MediaAsset]) throws {
        self.options = options; self.timeline = timeline; self.assets = assets
        grid = FrameGrid(timeline.canvas.frameRate)
        guard grid.isValid else { throw InterchangeError.invalidFrameRate(timeline.canvas.frameRate) }
        used = try InterchangeModel.usedAssets(timeline, assets)
        frame = .init(width: Double(timeline.canvas.width), height: Double(timeline.canvas.height))
        sequenceFormatID = "r1"
        nextID = 2
    }

    mutating func makeID() -> String { defer { nextID += 1 }; return "r\(nextID)" }

    // MARK: Time strings

    /// `f` frames of `g` as an FCPXML time: `"0s"`, `"3s"`, `"45/30s"`, `"1001/30000s"`.
    static func string(_ f: Int64, _ g: FrameGrid) -> String {
        let n = f * g.den, d = g.num
        return n % d == 0 ? "\(n / d)s" : "\(n)/\(d)s"
    }

    func seq(_ f: Int64) -> String { Self.string(f, grid) }

    /// Any time: on `preferred`'s (or the sequence's) grid when it lies on it, else as a reduced rational.
    func time(_ t: RationalTime, _ preferred: FrameGrid? = nil) -> String {
        for g in [preferred, grid].compactMap({ $0 }) { if let f = g.exactFrames(t) { return Self.string(f, g) } }
        let r = t.reduced
        return r.scale == 1 ? "\(r.value)s" : "\(r.value)/\(r.scale)s"
    }

    func mediaGrid(_ a: MediaAsset) -> FrameGrid {
        switch a.info.kind {
        case .audio:
            return FrameGrid(num: Int64(a.info.audioSampleRate > 0 ? a.info.audioSampleRate.rounded() : 48_000), den: 1)
        case .video:
            return a.info.frameRate > 0 ? FrameGrid(FrameRate.nearestStandard(to: a.info.frameRate)) : grid
        case .image:
            return grid
        }
    }

    // MARK: Document

    mutating func build() -> Data {
        let root = XMLElement(name: "fcpxml")
        root.attr("version", options.version.rawValue)

        let resources = XMLElement(name: "resources")
        let seqFormat = XMLElement(name: "format")
        seqFormat.attr("id", sequenceFormatID)
        seqFormat.attr("name", Self.formatName(width: timeline.canvas.width, height: timeline.canvas.height, rate: timeline.canvas.frameRate))
        seqFormat.attr("frameDuration", seq(1))
        seqFormat.attr("width", "\(timeline.canvas.width)")
        seqFormat.attr("height", "\(timeline.canvas.height)")
        seqFormat.attr("colorSpace", "1-1-1 (Rec. 709)")
        formats.append(seqFormat)
        formatIDs[Self.formatKey(width: timeline.canvas.width, height: timeline.canvas.height, grid: grid, transfer: .sdr)] = sequenceFormatID
        for asset in used { addAsset(asset) }

        let spine = buildSpine()

        for f in formats { resources.addChild(f) }
        if let titleEffectID {
            let effect = XMLElement(name: "effect")
            effect.attr("id", titleEffectID)
            effect.attr("name", "Basic Title")
            effect.attr("uid", FCPXMLExporter.basicTitleUID)
            resources.addChild(effect)
        }
        for a in assetElements { resources.addChild(a) }
        root.addChild(resources)

        let name = options.projectName ?? (timeline.name.isEmpty ? "Clipper Timeline" : timeline.name)
        let library = XMLElement(name: "library")
        let event = XMLElement(name: "event")
        event.attr("name", options.eventName)
        let project = XMLElement(name: "project")
        project.attr("name", name)
        let sequence = XMLElement(name: "sequence")
        sequence.attr("format", sequenceFormatID)
        sequence.attr("duration", seq(spine.total))
        sequence.attr("tcStart", "0s")
        sequence.attr("tcFormat", "NDF")
        sequence.attr("audioLayout", "stereo")
        sequence.attr("audioRate", "48k")
        sequence.addChild(spine.element)
        project.addChild(sequence)
        event.addChild(project)
        library.addChild(event)
        root.addChild(library)

        let doc = XMLDocument(rootElement: root)
        doc.version = "1.0"
        doc.characterEncoding = "UTF-8"
        let dtd = XMLDTD()
        dtd.name = "fcpxml"
        doc.dtd = dtd
        return doc.xmlData(options: [.nodePrettyPrint, .nodeCompactEmptyElement])
    }

    // MARK: Resources

    static func formatKey(width: Int, height: Int, grid: FrameGrid?, transfer: TransferFunction) -> String {
        "\(width)x\(height)@\(grid.map { "\($0.num)/\($0.den)" } ?? "still")/\(transfer.rawValue)"
    }

    /// FCP's name for standard formats ("FFVideoFormat1080p30"); nil for custom sizes such as 1080×1920.
    static func formatName(width: Int, height: Int, rate: FrameRate) -> String? {
        let size: String? = switch (width, height) {
        case (1920, 1080): "1080p"
        case (1280, 720): "720p"
        case (3840, 2160): "2160p"
        default: nil
        }
        let token: String? = switch (rate.numerator, rate.denominator) {
        case (24000, 1001): "2398"
        case (30000, 1001): "2997"
        case (60000, 1001): "5994"
        case (let n, 1) where [24, 25, 30, 50, 60].contains(n): "\(n)"
        default: nil
        }
        guard let size, let token else { return nil }
        return "FFVideoFormat\(size)\(token)"
    }

    static func colorSpace(_ t: TransferFunction) -> String {
        switch t {
        case .sdr: "1-1-1 (Rec. 709)"
        case .hlg: "9-18-9 (Rec. 2020 HLG)"
        case .pq: "9-16-9 (Rec. 2020 PQ)"
        }
    }

    mutating func addAsset(_ asset: MediaAsset) {
        let info = asset.info
        let id = makeID()
        assetIDs[asset.id] = id
        let el = XMLElement(name: "asset")
        el.attr("id", id)
        el.attr("name", asset.name.isEmpty ? asset.url.deletingPathExtension().lastPathComponent : asset.name)
        el.attr("start", "0s")
        let mg = mediaGrid(asset)
        el.attr("duration", info.kind == .image ? "0s" : Self.string(mg.frames(info.duration), mg))
        if info.hasVideo {
            el.attr("hasVideo", "1")
            el.attr("format", formatID(for: asset))
            el.attr("videoSources", "1")
        }
        if info.hasAudio {
            el.attr("hasAudio", "1")
            el.attr("audioSources", "1")
            el.attr("audioChannels", "\(info.audioChannels)")
            el.attr("audioRate", "\(Int(info.audioSampleRate > 0 ? info.audioSampleRate.rounded() : 48_000))")
        }
        let rep = XMLElement(name: "media-rep")
        rep.attr("kind", "original-media")
        rep.attr("src", asset.renderURL.absoluteString)
        el.addChild(rep)
        assetElements.append(el)
    }

    mutating func formatID(for asset: MediaAsset) -> String {
        let info = asset.info
        let w = info.displayWidth > 0 ? info.displayWidth : timeline.canvas.width
        let h = info.displayHeight > 0 ? info.displayHeight : timeline.canvas.height
        let still = info.kind == .image
        let g = still ? nil : mediaGrid(asset)
        let key = Self.formatKey(width: w, height: h, grid: g, transfer: info.transfer)
        if let id = formatIDs[key] { return id }
        let id = makeID()
        let f = XMLElement(name: "format")
        f.attr("id", id)
        if still {
            f.attr("name", "FFVideoFormatRateUndefined")
        } else if let g {
            f.attr("name", Self.formatName(width: w, height: h, rate: FrameRate(Int32(g.num), Int32(g.den))))
            f.attr("frameDuration", Self.string(1, g))
        }
        f.attr("width", "\(w)")
        f.attr("height", "\(h)")
        f.attr("colorSpace", Self.colorSpace(info.transfer))
        formats.append(f)
        formatIDs[key] = id
        return id
    }

    mutating func titleEffect() -> String {
        if let titleEffectID { return titleEffectID }
        let id = makeID()
        titleEffectID = id
        return id
    }

    // MARK: Spine

    mutating func buildSpine() -> (element: XMLElement, total: Int64) {
        let tracks = timeline.tracks
        let primary = InterchangeModel.primaryTrackIndex(timeline, override: options.primaryTrack)
        let placedByTrack = tracks.map { InterchangeModel.place($0.items, grid: grid) }
        let total = max(grid.frames(timeline.duration), placedByTrack.flatMap { $0.map(\.end) }.max() ?? 0)

        var nodes: [Node] = []
        var cursor: Int64 = 0
        /// Primary-track items that can't live in a spine (captions): anchored like a connected clip.
        var orphans: [InterchangeModel.Placed] = []
        if let p = primary {
            for placed in placedByTrack[p] {
                if placed.start > cursor { nodes.append(gap(cursor, placed.start - cursor)) }
                let offset = seq(placed.start)
                if let made = element(for: placed, track: tracks[p], lane: nil, offset: offset) {
                    nodes.append(Node(element: made.0, offset: placed.start, duration: placed.duration, localStart: made.1))
                } else {
                    nodes.append(gap(placed.start, placed.duration, name: placed.item.name))
                    if case .caption = placed.item.content { orphans.append(placed) }
                }
                cursor = placed.end
            }
        }
        if cursor < total { nodes.append(gap(cursor, total - cursor)) }

        // Lanes: visual tracks above the primary 1, 2, …; below it −1, −2, …; audio continues the negatives.
        var lanes: [Int: Int] = [:]
        let p = primary ?? -1
        let visual = tracks.indices.filter { $0 != p && tracks[$0].kind.isVisual }
        for (n, i) in visual.filter({ $0 > p }).enumerated() { lanes[i] = n + 1 }
        let below = Array(visual.filter { $0 < p }.reversed())
        for (n, i) in below.enumerated() { lanes[i] = -(n + 1) }
        for (n, i) in tracks.indices.filter({ $0 != p && !tracks[$0].kind.isVisual }).enumerated() {
            lanes[i] = -(below.count + n + 1)
        }

        func attach(_ placed: InterchangeModel.Placed, track: Track, lane: Int, to nodes: inout [Node], builder: inout FCPXMLBuilder) {
            // Parent: the last spine element starting at or before the item.
            var lo = 0, hi = nodes.count
            while lo < hi { let m = (lo + hi) / 2; if nodes[m].offset <= placed.start { lo = m + 1 } else { hi = m } }
            guard lo > 0 else { return }
            let parent = lo - 1
            let local = nodes[parent].localStart + builder.grid.time(placed.start - nodes[parent].offset)
            if let made = builder.element(for: placed, track: track, lane: lane, offset: builder.time(local)) {
                nodes[parent].anchored.append((local, lane, made.0))
            }
        }

        for (i, track) in tracks.enumerated() where i != p {
            guard let lane = lanes[i] else { continue }
            for placed in placedByTrack[i] { attach(placed, track: track, lane: lane, to: &nodes, builder: &self) }
        }
        if let p = primary {
            let lane = (lanes.values.max() ?? 0) + 1
            for placed in orphans { attach(placed, track: tracks[p], lane: max(lane, 1), to: &nodes, builder: &self) }
        }

        for marker in timeline.markers {
            let f = grid.frames(marker.time)
            guard let i = nodes.lastIndex(where: { $0.offset <= f }), f < nodes[i].offset + nodes[i].duration else { continue }
            let el = XMLElement(name: "marker")
            el.attr("start", time(nodes[i].localStart + grid.time(f - nodes[i].offset)))
            el.attr("duration", seq(1))
            el.attr("value", marker.name.isEmpty ? "Marker" : marker.name)
            nodes[i].markers.append(el)
        }

        let spine = XMLElement(name: "spine")
        for node in nodes {
            for a in node.anchored.sorted(by: { $0.offset != $1.offset ? $0.offset < $1.offset : $0.lane < $1.lane }) {
                node.element.addChild(a.element)
            }
            // DTD order: anchored items, then markers.
            for m in node.markers { node.element.addChild(m) }
            spine.addChild(node.element)
        }
        return (spine, total)
    }

    func gap(_ offset: Int64, _ duration: Int64, name: String? = nil) -> Node {
        let el = XMLElement(name: "gap")
        el.attr("name", name.flatMap { $0.isEmpty ? nil : $0 } ?? "Gap")
        el.attr("offset", seq(offset))
        el.attr("duration", seq(duration))
        return Node(element: el, offset: offset, duration: duration, localStart: .zero)
    }

    // MARK: Story elements

    /// The element for an item, and its local start time. Nil for content FCPXML can't carry here (solids, omitted
    /// captions).
    mutating func element(for placed: InterchangeModel.Placed, track: Track, lane: Int?, offset: String) -> (XMLElement, RationalTime)? {
        let item = placed.item
        switch item.content {
        case .media(let ref):
            guard let asset = assets[ref.asset] else { return nil }
            if asset.info.kind == .image { return stillElement(placed, track: track, asset: asset, lane: lane, offset: offset) }
            return mediaElement(placed, track: track, asset: asset, ref: ref, lane: lane, offset: offset)
        case .image(let id):
            guard let asset = assets[id] else { return nil }
            return stillElement(placed, track: track, asset: asset, lane: lane, offset: offset)
        case .text(let text):
            let style = timeline.styles[text.style] ?? TextStyle()
            return titleElement(placed, track: track, text: style.uppercase ? text.text.uppercased() : text.text,
                                style: style, lane: lane, offset: offset)
        case .caption(let caption):
            guard lane != nil, !caption.words.isEmpty else { return nil }
            let style = timeline.styles[caption.style] ?? TextStyle()
            let text = CaptionLanguage.join(caption.words.map(\.text), language: track.language)
            switch options.captionMode {
            case .omit: return nil
            case .titles:
                return titleElement(placed, track: track, text: style.uppercase ? text.uppercased() : text, style: style,
                                    lane: lane, offset: offset)
            case .captions:
                return captionElement(placed, track: track, text: text, style: style, lane: lane!, offset: offset)
            }
        case .solid:
            return nil
        }
    }

    mutating func mediaElement(_ placed: InterchangeModel.Placed, track: Track, asset: MediaAsset, ref: MediaRef,
                               lane: Int?, offset: String) -> (XMLElement, RationalTime) {
        let item = placed.item, info = asset.info, mg = mediaGrid(asset)
        let videoOn = info.hasVideo && track.kind.isVisual && !track.hidden
        let audioOn = info.hasAudio && ref.useAudio && track.kind.hasAudio && !track.muted

        let el = XMLElement(name: "asset-clip")
        el.attr("ref", assetIDs[asset.id]!)
        el.attr("lane", lane.map(String.init))
        el.attr("offset", offset)
        el.attr("name", item.name.isEmpty ? asset.name : item.name)

        let retimed = abs(ref.speed - 1) > 1e-9 && ref.speed > 0
        let local: RationalTime
        var timeMap: XMLElement?
        if retimed {
            // Local (retimed) time S maps to the source start; FCP's `start` lives in the retimed domain.
            let s = grid.frames(RationalTime(seconds: ref.source.start.seconds / ref.speed))
            local = grid.time(s)
            let map = XMLElement(name: "timeMap")
            func point(_ t: String, _ v: String) {
                let p = XMLElement(name: "timept")
                p.attr("time", t); p.attr("value", v); p.attr("interp", "linear")
                map.addChild(p)
            }
            if s > 0 { point("0s", "0s") }
            point(seq(s), time(ref.source.start, mg))
            point(seq(s + placed.duration), time(ref.source.end, mg))
            timeMap = map
        } else {
            local = mg.time(mg.frames(ref.source.start))
        }
        el.attr("start", time(local, retimed ? grid : mg))
        el.attr("duration", seq(placed.duration))
        if info.hasVideo && info.hasAudio && videoOn != audioOn { el.attr("srcEnable", videoOn ? "video" : "audio") }
        if !videoOn && !audioOn { el.attr("enabled", "0") }
        switch track.kind {
        case .music: el.attr("audioRole", "music")
        case .audio: el.attr("audioRole", "dialogue")
        default: break
        }

        if let timeMap { el.addChild(timeMap) }
        if info.hasVideo && track.kind.isVisual {
            let source = FCPGeometry.Frame(width: Double(info.displayWidth), height: Double(info.displayHeight))
            for c in videoAdjustments(item, placed: placed, local: local, source: source) { el.addChild(c) }
        }
        if audioOn, let v = volume(item, track: track, placed: placed, local: local) { el.addChild(v) }
        return (el, local)
    }

    mutating func stillElement(_ placed: InterchangeModel.Placed, track: Track, asset: MediaAsset, lane: Int?,
                               offset: String) -> (XMLElement, RationalTime) {
        let el = XMLElement(name: "video")
        el.attr("ref", assetIDs[asset.id]!)
        el.attr("lane", lane.map(String.init))
        el.attr("offset", offset)
        el.attr("name", placed.item.name.isEmpty ? asset.name : placed.item.name)
        el.attr("duration", seq(placed.duration))
        if track.hidden { el.attr("enabled", "0") }
        let source = FCPGeometry.Frame(width: Double(asset.info.displayWidth), height: Double(asset.info.displayHeight))
        for c in videoAdjustments(placed.item, placed: placed, local: .zero, source: source) { el.addChild(c) }
        return (el, .zero)
    }

    mutating func titleElement(_ placed: InterchangeModel.Placed, track: Track, text: String, style: TextStyle,
                               lane: Int?, offset: String) -> (XMLElement, RationalTime) {
        let el = XMLElement(name: "title")
        el.attr("ref", titleEffect())
        el.attr("lane", lane.map(String.init))
        el.attr("offset", offset)
        el.attr("name", Self.clipName(text))
        el.attr("duration", seq(placed.duration))
        if track.hidden { el.attr("enabled", "0") }

        styleCount += 1
        let styleID = "ts\(styleCount)"
        let textEl = XMLElement(name: "text")
        let run = XMLElement(name: "text-style", stringValue: text)
        run.attr("ref", styleID)
        textEl.addChild(run)
        el.addChild(textEl)
        el.addChild(styleDef(styleID, titleStyle(style)))

        // Basic Title draws text centred in the frame; move/scale/rotate it with the clip transform.
        let item = placed.item
        let times = keyTimes(item.transform.position.keyItems, item.transform.scale.keyItems,
                             item.transform.rotation.keyItems)
        if let t = transformElement(times: times, local: .zero, sample: { FCPGeometry.text(item.transform, at: $0, frame: frame) }) {
            el.addChild(t)
        }
        if let b = blend(item, placed: placed, local: .zero) { el.addChild(b) }
        return (el, .zero)
    }

    mutating func captionElement(_ placed: InterchangeModel.Placed, track: Track, text: String, style: TextStyle,
                                 lane: Int, offset: String) -> (XMLElement, RationalTime) {
        let el = XMLElement(name: "caption")
        el.attr("lane", "\(lane)")
        el.attr("offset", offset)
        el.attr("name", Self.clipName(text))
        el.attr("duration", seq(placed.duration))
        el.attr("role", "iTT?captionFormat=ITT.\(track.language ?? "en")")

        styleCount += 1
        let styleID = "ts\(styleCount)"
        let textEl = XMLElement(name: "text")
        textEl.attr("placement", style.position.y < 0.5 ? "top" : "bottom")
        let run = XMLElement(name: "text-style", stringValue: text)
        run.attr("ref", styleID)
        textEl.addChild(run)
        el.addChild(textEl)
        var attrs: [(String, String)] = [("font", Self.fontFamily(style.font).family),
                                         ("fontColor", Self.color(style.color))]
        if Self.fontFamily(style.font).bold { attrs.append(("bold", "1")) }
        if let box = style.box { attrs.append(("backgroundColor", Self.color(box.color))) }
        el.addChild(styleDef(styleID, attrs))
        return (el, .zero)
    }

    static func clipName(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 40 ? String(flat.prefix(40)) + "…" : flat
    }

    func styleDef(_ id: String, _ attrs: [(String, String)]) -> XMLElement {
        let def = XMLElement(name: "text-style-def")
        def.attr("id", id)
        let ts = XMLElement(name: "text-style")
        for (k, v) in attrs { ts.attr(k, v) }
        def.addChild(ts)
        return def
    }

    /// Basic Title text attributes. Font size: Clipper sizes are fractions of the canvas height; FCP title sizes are
    /// in frame pixels, so `size × height`.
    func titleStyle(_ style: TextStyle) -> [(String, String)] {
        let size = style.size * frame.height
        let font = Self.fontFamily(style.font)
        var a: [(String, String)] = [("font", font.family), ("fontSize", decimal(size, digits: 2)), ("fontFace", font.face),
                                     ("fontColor", Self.color(style.color))]
        if font.bold { a.append(("bold", "1")) }
        if let stroke = style.stroke, style.strokeWidth > 0 {
            a.append(("strokeColor", Self.color(stroke)))
            a.append(("strokeWidth", decimal(style.strokeWidth * size, digits: 2)))
        }
        if let shadow = style.shadow {
            a.append(("shadowColor", Self.color(shadow.color)))
            a.append(("shadowBlurRadius", decimal(shadow.radius * size, digits: 2)))
        }
        a.append(("alignment", style.alignment.rawValue))
        if abs(style.lineSpacing - 1) > 1e-9 { a.append(("lineSpacing", decimal((style.lineSpacing - 1) * size, digits: 2))) }
        return a
    }

    static func color(_ c: RGBA) -> String { [c.r, c.g, c.b, c.a].map { decimal($0) }.joined(separator: " ") }

    /// PostScript name → (family, face): "HelveticaNeue-BoldItalic" → ("Helvetica Neue", "Bold Italic").
    static func fontFamily(_ postScript: String) -> (family: String, face: String, bold: Bool) {
        func spaced(_ s: Substring) -> String {
            var out = ""
            var prev: Character?
            for ch in s {
                if let p = prev, ch.isUppercase, p.isLowercase { out.append(" ") }
                out.append(ch); prev = ch
            }
            return out
        }
        let parts = postScript.split(separator: "-", maxSplits: 1)
        let family = parts.first.map(spaced) ?? postScript
        let face = parts.count > 1 ? spaced(parts[1]) : "Regular"
        let bold = ["Bold", "Black", "Heavy", "Semibold", "Extrabold"].contains { face.localizedCaseInsensitiveContains($0) }
        return (family.isEmpty ? "Helvetica" : family, face, bold)
    }

    // MARK: Adjustments

    struct KeyTime: Equatable { var rel: RationalTime; var interp: Interpolation }

    /// Union of keyframe times (item-relative), adding a key one frame before each key after a `hold`.
    func keyTimes(_ lists: [KeyTime]...) -> [(frames: Int64, interp: Interpolation)] {
        var byFrame: [Int64: Interpolation] = [:]
        for list in lists {
            for (i, k) in list.enumerated() {
                let f = grid.frames(k.rel)
                if byFrame[f] == nil { byFrame[f] = k.interp }
                if k.interp == .hold, i + 1 < list.count {
                    let nf = grid.frames(list[i + 1].rel) - 1
                    if nf > f, byFrame[nf] == nil { byFrame[nf] = .linear }
                }
            }
        }
        return byFrame.keys.sorted().map { ($0, byFrame[$0]!) }
    }

    func keyframe(_ local: RationalTime, _ f: Int64, _ value: String, _ interp: Interpolation) -> XMLElement {
        let k = XMLElement(name: "keyframe")
        k.attr("time", time(local + grid.time(f)))
        k.attr("value", value)
        switch interp {
        case .linear, .hold: k.attr("interp", "linear"); k.attr("curve", "linear")
        case .easeInOut: k.attr("interp", "ease")
        case .easeIn: k.attr("interp", "easeIn")
        case .easeOut: k.attr("interp", "easeOut")
        }
        return k
    }

    func param(_ name: String, fadeIn: String? = nil, fadeOut: String? = nil, keys: [XMLElement] = []) -> XMLElement {
        let p = XMLElement(name: "param")
        p.attr("name", name)
        if let fadeIn {
            let f = XMLElement(name: "fadeIn"); f.attr("type", "linear"); f.attr("duration", fadeIn); p.addChild(f)
        }
        if let fadeOut {
            let f = XMLElement(name: "fadeOut"); f.attr("type", "linear"); f.attr("duration", fadeOut); p.addChild(f)
        }
        if !keys.isEmpty {
            let anim = XMLElement(name: "keyframeAnimation")
            for k in keys { anim.addChild(k) }
            p.addChild(anim)
        }
        return p
    }

    /// `adjust-crop` (trim) + `adjust-transform` + `adjust-blend` for a media or still layer.
    func videoAdjustments(_ item: Item, placed: InterchangeModel.Placed, local: RationalTime,
                          source: FCPGeometry.Frame) -> [XMLElement] {
        let tr = item.transform
        let src = FCPGeometry.Frame(width: source.width > 0 ? source.width : frame.width,
                                    height: source.height > 0 ? source.height : frame.height)
        let times = keyTimes(tr.position.keyItems, tr.scale.keyItems, tr.rotation.keyItems, tr.zoom.keyItems, tr.focus.keyItems)
        let sample = { (t: RationalTime) in FCPGeometry.media(tr, at: t, frame: frame, source: src) }
        var out: [XMLElement] = []
        let first = sample(times.first.map { grid.time($0.frames) } ?? .zero)
        let anyUncovered = !first.coversFrame || times.contains { !sample(grid.time($0.frames)).coversFrame }
        if anyUncovered, let trim = FCPGeometry.trim(first, frame: frame, source: src) {
            let crop = XMLElement(name: "adjust-crop")
            crop.attr("mode", "trim")
            let rect = XMLElement(name: "trim-rect")
            rect.attr("left", decimal(trim.left)); rect.attr("top", decimal(trim.top))
            rect.attr("right", decimal(trim.right)); rect.attr("bottom", decimal(trim.bottom))
            crop.addChild(rect)
            out.append(crop)
        }
        if let t = transformElement(times: times, local: local, sample: sample) { out.append(t) }
        if let b = blend(item, placed: placed, local: local) { out.append(b) }
        return out
    }

    func transformElement(times: [(frames: Int64, interp: Interpolation)], local: RationalTime,
                          sample: (RationalTime) -> FCPGeometry.Sample) -> XMLElement? {
        func pos(_ s: FCPGeometry.Sample) -> String { "\(decimal(s.positionX)) \(decimal(s.positionY))" }
        func scl(_ s: FCPGeometry.Sample) -> String { "\(decimal(s.scaleX, digits: 6)) \(decimal(s.scaleY, digits: 6))" }
        func rot(_ s: FCPGeometry.Sample) -> String { decimal(s.rotation) }

        let samples = times.map { (f: $0.frames, interp: $0.interp, s: sample(grid.time($0.frames))) }
        let initial = samples.first?.s ?? sample(.zero)
        if samples.count <= 1 && initial.isIdentity { return nil }
        let el = XMLElement(name: "adjust-transform")
        el.attr("position", pos(initial))
        el.attr("scale", scl(initial))
        el.attr("rotation", rot(initial))
        if samples.count > 1 {
            for (name, value) in [("position", pos), ("scale", scl), ("rotation", rot)] as [(String, (FCPGeometry.Sample) -> String)] {
                let values = samples.map { value($0.s) }
                guard Set(values).count > 1 else { continue }
                el.addChild(param(name, keys: zip(samples, values).map { keyframe(local, $0.f, $1, $0.interp) }))
            }
            if el.childCount == 0 && initial.isIdentity { return nil }
        }
        return el
    }

    func blend(_ item: Item, placed: InterchangeModel.Placed, local: RationalTime) -> XMLElement? {
        let fadeIn = grid.frames(item.fadeIn), fadeOut = grid.frames(item.fadeOut)
        let animated = item.opacity.isAnimated
        let initial = item.opacity.value(at: .zero)
        guard animated || abs(initial - 1) > 1e-9 || fadeIn > 0 || fadeOut > 0 else { return nil }
        let el = XMLElement(name: "adjust-blend")
        el.attr("amount", decimal(initial))
        if animated || fadeIn > 0 || fadeOut > 0 {
            let keys = animated ? keyTimes(item.opacity.keyItems).map { k in
                keyframe(local, k.frames, decimal(item.opacity.value(at: grid.time(k.frames))), k.interp)
            } : []
            el.addChild(param("amount", fadeIn: fadeIn > 0 ? seq(fadeIn) : nil, fadeOut: fadeOut > 0 ? seq(fadeOut) : nil, keys: keys))
        }
        return el
    }

    /// `adjust-volume` in dB: item gain (keyframes = ducking) plus track gain, with linear fades.
    func volume(_ item: Item, track: Track, placed: InterchangeModel.Placed, local: RationalTime) -> XMLElement? {
        let fadeIn = grid.frames(item.fadeIn), fadeOut = grid.frames(item.fadeOut)
        let animated = item.gain.isAnimated
        let initial = InterchangeModel.gainDB(item, track: track, at: .zero)
        guard animated || abs(initial) > 1e-9 || fadeIn > 0 || fadeOut > 0 else { return nil }
        func db(_ x: Double) -> String { decimal(x, digits: 2) + "dB" }
        let el = XMLElement(name: "adjust-volume")
        el.attr("amount", db(initial))
        if animated || fadeIn > 0 || fadeOut > 0 {
            let keys = animated ? keyTimes(item.gain.keyItems).map { k in
                keyframe(local, k.frames, db(InterchangeModel.gainDB(item, track: track, at: grid.time(k.frames))), k.interp)
            } : []
            el.addChild(param("amount", fadeIn: fadeIn > 0 ? seq(fadeIn) : nil, fadeOut: fadeOut > 0 ? seq(fadeOut) : nil, keys: keys))
        }
        return el
    }
}

extension Param {
    fileprivate var keyItems: [FCPXMLBuilder.KeyTime] { keys.map { .init(rel: $0.time, interp: $0.interpolation) } }
}

extension XMLElement {
    /// Adds an attribute in document order; nil values are skipped.
    fileprivate func attr(_ name: String, _ value: String?) {
        guard let value else { return }
        let node = XMLNode.attribute(withName: name, stringValue: value) as! XMLNode
        addAttribute(node)
    }
}
