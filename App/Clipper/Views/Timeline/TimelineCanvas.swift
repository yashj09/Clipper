import AppKit
import ClipperCore
import ClipperEngine
import QuartzCore

/// What the timeline asks its owner to do. Edits are expressed as model commands, never applied here.
@MainActor
protocol TimelineCanvasDelegate: AnyObject {
    func timelineSelect(_ ids: Set<ItemID>)
    func timelineSeek(_ time: RationalTime)
    func timelineMove(_ id: ItemID, toTrack: TrackID, start: RationalTime)
    func timelineTrim(_ id: ItemID, edge: TrimEdge, to: RationalTime, ripple: Bool)
    func timelineToggle(_ track: TrackID, _ property: TimelineCanvas.TrackToggle)
    func timelineKey(_ action: TimelineCanvas.KeyAction)
}

/// Pro-NLE timeline drawn with Core Animation (Phase 0 S4: virtualized layers + level of detail stay at 120 fps).
final class TimelineCanvas: NSView {
    enum TrackToggle { case mute, hide, lock }
    enum KeyAction { case playPause, shuttleBack, stop, shuttleForward, stepBack, stepForward, blade, delete, rippleDelete, home, end, zoomFit }

    // Layout
    static let rulerHeight: CGFloat = 26
    static let headerWidth: CGFloat = 132
    static let trackGap: CGFloat = 2

    weak var delegate: TimelineCanvasDelegate?

    // State pushed from SwiftUI
    var timeline: Timeline? { didSet { layoutTimeline(rebuildRows: true) } }
    var selection: Set<ItemID> = [] { didSet { if selection != oldValue { layoutTimeline() } } }
    var playhead: RationalTime = .zero { didSet { if playhead != oldValue { positionPlayhead(); autoScrollToPlayhead() } } }
    var assets: [AssetID: MediaAsset] = [:]
    var snapping = true
    var rippleByDefault = true

    /// Zoom (points per second) and horizontal scroll (seconds at the left edge).
    private(set) var pxPerSecond: CGFloat = 60
    private(set) var scrollSeconds: Double = 0
    private var scrollY: CGFloat = 0

    // Rows in display order (top to bottom): visual tracks reversed (top layer first), then audio.
    private struct Row { var track: Track; var y: CGFloat; var height: CGFloat }
    private var rows: [Row] = []

    // Layers
    private let itemsLayer = CALayer()
    private let summaryLayer = CALayer()
    private let playheadLayer = CALayer()
    private let ghostLayer = CALayer()
    private var pool: [ItemLayer] = []
    private var active: [ItemID: ItemLayer] = [:]
    private let ruler = RulerView()
    private let headers = HeaderView()

    // Async media
    private var waveforms: [AssetID: WaveformPeaks] = [:]
    private var waveformRequests = Set<AssetID>()
    private var thumbs: [String: CGImage] = [:]
    private var thumbRequests = Set<String>()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.11, alpha: 1).cgColor
        layer?.masksToBounds = true
        itemsLayer.masksToBounds = true
        layer?.addSublayer(itemsLayer)
        itemsLayer.addSublayer(summaryLayer)
        ghostLayer.borderColor = NSColor.white.cgColor
        ghostLayer.borderWidth = 1.5
        ghostLayer.cornerRadius = 4
        ghostLayer.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        ghostLayer.isHidden = true
        itemsLayer.addSublayer(ghostLayer)
        playheadLayer.backgroundColor = NSColor.systemRed.cgColor
        playheadLayer.zPosition = 10
        layer?.addSublayer(playheadLayer)
        ruler.canvas = self
        headers.canvas = self
        addSubview(ruler)
        addSubview(headers)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Geometry

    func x(for t: Double) -> CGFloat { Self.headerWidth + CGFloat(t - scrollSeconds) * pxPerSecond }
    func time(at x: CGFloat) -> Double { max(0, scrollSeconds + Double((x - Self.headerWidth) / pxPerSecond)) }
    private var visibleSeconds: Double { Double((bounds.width - Self.headerWidth) / pxPerSecond) }

    static func height(for kind: TrackKind) -> CGFloat {
        switch kind {
        case .video: 66
        case .overlay: 50
        case .title, .caption: 34
        case .audio, .music: 46
        }
    }

    override func layout() {
        super.layout()
        ruler.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.rulerHeight)
        headers.frame = CGRect(x: 0, y: Self.rulerHeight, width: Self.headerWidth, height: bounds.height - Self.rulerHeight)
        itemsLayer.frame = CGRect(x: 0, y: Self.rulerHeight, width: bounds.width, height: bounds.height - Self.rulerHeight)
        layoutTimeline()
    }

    // MARK: Layout

    func layoutTimeline(rebuildRows: Bool = false) {
        guard let timeline else { return }
        if rebuildRows || rows.count != timeline.tracks.count {
            let visual = timeline.tracks.filter { $0.kind.isVisual }.reversed()
            let audio = timeline.tracks.filter { !$0.kind.isVisual }
            var y: CGFloat = 4
            rows = (Array(visual) + audio).map { t in
                defer { y += Self.height(for: t.kind) + Self.trackGap }
                return Row(track: t, y: y, height: Self.height(for: t.kind))
            }
            headers.needsDisplay = true
        } else {
            // Refresh track contents in place (edits don't change the row structure).
            let byID = Dictionary(uniqueKeysWithValues: timeline.tracks.map { ($0.id, $0) })
            for i in rows.indices { if let t = byID[rows[i].track.id] { rows[i].track = t } }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let start = scrollSeconds, end = scrollSeconds + visibleSeconds
        let avgItemPx = averageItemSeconds * pxPerSecond
        var keep = Set<ItemID>()
        if avgItemPx < 6 {
            drawSummary()
        } else {
            summaryLayer.isHidden = true
            for row in rows {
                for item in row.track.items(in: TimeRange(start: RationalTime(seconds: start), end: RationalTime(seconds: end + 0.001))) {
                    keep.insert(item.id)
                    let l = active[item.id] ?? dequeue(item.id)
                    let x0 = x(for: item.start.seconds), x1 = x(for: item.end.seconds)
                    l.frame = CGRect(x: x0, y: row.y - scrollY, width: max(2, x1 - x0 - 1), height: row.height)
                    configure(l, item: item, track: row.track)
                }
            }
        }
        for (id, l) in active where !keep.contains(id) { l.removeFromSuperlayer(); pool.append(l); active[id] = nil }
        positionPlayhead()
        ruler.needsDisplay = true
        headers.needsDisplay = true
    }

    private var averageItemSeconds: CGFloat {
        guard let t = timeline, !t.allItems.isEmpty else { return 10 }
        return CGFloat(t.duration.seconds) / CGFloat(max(1, t.allItems.count / max(1, t.tracks.count)))
    }

    private func dequeue(_ id: ItemID) -> ItemLayer {
        let l = pool.popLast() ?? ItemLayer()
        itemsLayer.insertSublayer(l, below: ghostLayer)
        active[id] = l
        return l
    }

    private func configure(_ l: ItemLayer, item: Item, track: Track) {
        let selected = selection.contains(item.id)
        l.apply(item: item, kind: track.kind, selected: selected, dimmed: track.hidden || track.muted)
        guard l.bounds.width > 24, case .media(let ref) = item.content, let asset = assets[ref.asset] else {
            l.setThumbnails([]); l.setWaveform(nil); return
        }
        if track.kind.isVisual && asset.info.hasVideo {
            // One thumbnail per tile; tile width follows the source aspect at the row height.
            let tileW = max(40, (l.bounds.height - 16) * CGFloat(asset.info.displayAspect))
            let count = min(40, Int(ceil(l.bounds.width / tileW)))
            var images: [CGImage?] = []
            for i in 0..<count {
                let localSeconds = Double(CGFloat(i) * tileW / pxPerSecond)
                let src = ref.source.start.seconds + localSeconds * ref.speed
                images.append(thumbnail(asset, at: src))
            }
            l.setThumbnails(images, tileWidth: tileW)
        } else {
            l.setThumbnails([])
        }
        if (track.kind.hasAudio && !track.kind.isVisual) || (track.kind == .video && ref.useAudio && asset.info.hasAudio && l.bounds.height > 60) {
            if let peaks = waveform(asset) {
                let cols = Int(l.bounds.width / 2)
                l.setWaveform(peaks.peaks(from: ref.source.start.seconds, to: ref.source.end.seconds, columns: max(1, cols)), columnWidth: 2)
            }
        } else {
            l.setWaveform(nil)
        }
    }

    private func thumbnail(_ asset: MediaAsset, at seconds: Double) -> CGImage? {
        let grid = max(0.5, Double(60 / pxPerSecond))
        let q = (seconds / grid).rounded() * grid
        let key = "\(asset.id)|\(q)"
        if let img = thumbs[key] { return img }
        if thumbRequests.insert(key).inserted {
            let url = asset.proxyURL ?? asset.renderURL
            Task { [weak self] in
                let img = await Thumbnailer.shared.thumbnail(url, at: q, height: 64, grid: grid)
                guard let self else { return }
                self.thumbs[key] = img
                self.layoutTimeline()
            }
        }
        return nil
    }

    private func waveform(_ asset: MediaAsset) -> WaveformPeaks? {
        if let w = waveforms[asset.id] { return w }
        if waveformRequests.insert(asset.id).inserted {
            let url = asset.renderURL
            Task { [weak self] in
                let peaks = try? await WaveformPeaks.build(url: url)
                guard let self else { return }
                self.waveforms[asset.id] = peaks
                self.layoutTimeline()
            }
        }
        return nil
    }

    private func drawSummary() {
        summaryLayer.isHidden = false
        guard let timeline else { return }
        let w = Int(max(1, bounds.width)), h = Int(max(1, itemsLayer.bounds.height))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return }
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        for row in rows {
            ctx.setFillColor(ItemLayer.color(row.track.kind).cgColor)
            for item in row.track.items {
                let x0 = x(for: item.start.seconds), x1 = x(for: item.end.seconds)
                ctx.fill(CGRect(x: x0, y: row.y - scrollY + 6, width: max(1, x1 - x0), height: row.height - 12))
            }
        }
        _ = timeline
        summaryLayer.frame = itemsLayer.bounds
        summaryLayer.contents = ctx.makeImage()
    }

    private func positionPlayhead() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let px = x(for: playhead.seconds)
        playheadLayer.frame = CGRect(x: px - 0.75, y: 0, width: 1.5, height: bounds.height)
        playheadLayer.isHidden = px < Self.headerWidth
        CATransaction.commit()
        ruler.needsDisplay = true
    }

    private func autoScrollToPlayhead() {
        guard dragState == nil else { return }
        let px = x(for: playhead.seconds)
        if px > bounds.width - 40 || px < Self.headerWidth {
            scrollSeconds = max(0, playhead.seconds - visibleSeconds * 0.1)
            layoutTimeline()
        }
    }

    func zoom(by factor: CGFloat, around x: CGFloat) {
        let anchor = time(at: x)
        pxPerSecond = min(2000, max(0.5, pxPerSecond * factor))
        scrollSeconds = max(0, anchor - Double((x - Self.headerWidth) / pxPerSecond))
        layoutTimeline()
    }

    func zoomToFit() {
        guard let d = timeline?.duration.seconds, d > 0 else { return }
        pxPerSecond = max(0.5, (bounds.width - Self.headerWidth - 30) / CGFloat(d))
        scrollSeconds = 0
        layoutTimeline()
    }

    // MARK: Interaction

    private enum DragState {
        case scrub
        case move(item: Item, fromTrack: TrackID, grabOffset: Double)
        case trim(item: Item, edge: TrimEdge)
    }
    private var dragState: DragState?
    private var dragTarget: (track: TrackID, time: RationalTime)?

    private func row(at y: CGFloat) -> Row? {
        let ly = y - Self.rulerHeight + scrollY
        return rows.first { ly >= $0.y && ly < $0.y + $0.height }
    }

    private func hit(_ p: CGPoint) -> (Item, Row, TrimEdge?)? {
        guard p.x > Self.headerWidth, let row = row(at: p.y) else { return nil }
        let t = time(at: p.x)
        guard let item = row.track.items.first(where: { $0.start.seconds <= t && t < $0.end.seconds }) else { return nil }
        let x0 = x(for: item.start.seconds), x1 = x(for: item.end.seconds)
        let handle = min(8, (x1 - x0) / 4)
        if p.x - x0 < handle { return (item, row, .start) }
        if x1 - p.x < handle { return (item, row, .end) }
        return (item, row, nil)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        if p.y < Self.rulerHeight || p.x <= Self.headerWidth && p.y < Self.rulerHeight {
            dragState = .scrub
            delegate?.timelineSeek(RationalTime(seconds: time(at: p.x)))
            return
        }
        guard p.x > Self.headerWidth else { return }
        if let (item, row, edge) = hit(p) {
            var sel = selection
            if event.modifierFlags.contains(.shift) { if sel.contains(item.id) { sel.remove(item.id) } else { sel.insert(item.id) } }
            else if !sel.contains(item.id) { sel = [item.id] }
            delegate?.timelineSelect(sel)
            guard !row.track.locked, !item.locked else { return }
            if let edge { dragState = .trim(item: item, edge: edge) }
            else { dragState = .move(item: item, fromTrack: row.track.id, grabOffset: time(at: p.x) - item.start.seconds) }
        } else {
            delegate?.timelineSelect([])
            delegate?.timelineSeek(RationalTime(seconds: time(at: p.x)))
            dragState = .scrub
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let state = dragState, let timeline else { return }
        let rate = timeline.canvas.frameRate
        switch state {
        case .scrub:
            delegate?.timelineSeek(RationalTime(seconds: time(at: p.x)))
        case .move(let item, let fromTrack, let grab):
            var start = max(0, time(at: p.x) - grab)
            let duration = item.range.duration.seconds
            start = snap(start, exclude: item.id, alsoEnd: duration)
            let target = row(at: p.y).flatMap { r in compatible(r.track.kind, with: item) ? r : nil }
                ?? rows.first { $0.track.id == fromTrack }!
            let st = RationalTime(seconds: start).roundedToFrame(rate)
            dragTarget = (target.track.id, st)
            showGhost(x0: x(for: st.seconds), x1: x(for: st.seconds + duration), row: target)
        case .trim(let item, let edge):
            var t = time(at: p.x)
            t = snap(t, exclude: item.id, alsoEnd: nil)
            let st = RationalTime(seconds: t).roundedToFrame(rate)
            dragTarget = (rows.first { $0.track.items.contains { $0.id == item.id } }!.track.id, st)
            let r = rows.first { $0.track.items.contains { $0.id == item.id } }!
            let x0 = edge == .start ? x(for: st.seconds) : x(for: item.start.seconds)
            let x1 = edge == .end ? x(for: st.seconds) : x(for: item.end.seconds)
            showGhost(x0: min(x0, x1), x1: max(x0, x1), row: r)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragState = nil; dragTarget = nil; ghostLayer.isHidden = true }
        guard let state = dragState, let target = dragTarget else { return }
        switch state {
        case .scrub: break
        case .move(let item, let fromTrack, _):
            if target.time != item.start || target.track != fromTrack { delegate?.timelineMove(item.id, toTrack: target.track, start: target.time) }
        case .trim(let item, let edge):
            let ripple = rippleByDefault != event.modifierFlags.contains(.option)
            if target.time != (edge == .start ? item.start : item.end) { delegate?.timelineTrim(item.id, edge: edge, to: target.time, ripple: ripple) }
        }
    }

    private func compatible(_ kind: TrackKind, with item: Item) -> Bool {
        switch item.content {
        case .media: kind == .video || kind == .overlay || kind == .audio || kind == .music
        case .caption: kind == .caption
        case .text, .solid, .image: kind.isVisual
        }
    }

    private func showGhost(x0: CGFloat, x1: CGFloat, row: Row) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ghostLayer.isHidden = false
        ghostLayer.frame = CGRect(x: x0, y: row.y - scrollY, width: max(2, x1 - x0), height: row.height)
        CATransaction.commit()
    }

    /// Snaps to the playhead and other items' edges within 8 points.
    private func snap(_ t: Double, exclude: ItemID, alsoEnd duration: Double?) -> Double {
        guard snapping, let timeline else { return t }
        var candidates = [0, playhead.seconds]
        for track in timeline.tracks { for i in track.items where i.id != exclude { candidates += [i.start.seconds, i.end.seconds] } }
        let tolerance = Double(8 / pxPerSecond)
        var best = t, bestD = tolerance
        for c in candidates {
            if abs(c - t) < bestD { best = c; bestD = abs(c - t) }
            if let d = duration, abs(c - (t + d)) < bestD { best = c - d; bestD = abs(c - (t + d)) }
        }
        return max(0, best)
    }

    /// NLE keys while the timeline has focus (kept off the menu so they don't steal keystrokes from text fields).
    override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        let action: KeyAction? = switch (event.charactersIgnoringModifiers?.lowercased(), event.keyCode) {
        case (" ", _): .playPause
        case ("j", _): .shuttleBack
        case ("k", _): .stop
        case ("l", _): .shuttleForward
        case ("b", _): .blade
        case (_, 123): .stepBack          // ←
        case (_, 124): .stepForward       // →
        case (_, 51), (_, 117): shift ? .rippleDelete : .delete   // ⌫ / ⌦
        case (_, 115): .home
        case (_, 119): .end
        case ("\\", _): .zoomFit
        default: nil
        }
        if action == .zoomFit { zoomToFit() } else if let action { delegate?.timelineKey(action) } else { super.keyDown(with: event) }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            zoom(by: pow(1.01, event.scrollingDeltaY), around: convert(event.locationInWindow, from: nil).x)
            return
        }
        let dx = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.scrollingDeltaX * 10
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
        if abs(dx) > abs(dy) || event.modifierFlags.contains(.shift) {
            scrollSeconds = max(0, scrollSeconds - Double((abs(dx) > abs(dy) ? dx : dy) / pxPerSecond))
        } else {
            let content = (rows.last.map { $0.y + $0.height } ?? 0) + 20
            scrollY = min(max(0, scrollY - dy), max(0, content - itemsLayer.bounds.height))
        }
        layoutTimeline()
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, around: convert(event.locationInWindow, from: nil).x)
    }

    override func resetCursorRects() {
        addCursorRect(CGRect(x: Self.headerWidth, y: 0, width: bounds.width, height: Self.rulerHeight), cursor: .pointingHand)
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let (_, _, edge) = hit(p), edge != nil { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    // Header clicks (mute / hide / lock).
    fileprivate func headerClicked(at p: CGPoint) {
        guard let row = row(at: p.y + Self.rulerHeight) else { return }
        let toggles: [TrackToggle] = [.hide, .mute, .lock]
        let index = Int((p.x - (Self.headerWidth - 66)) / 22)
        if (0..<3).contains(index), p.x > Self.headerWidth - 66 { delegate?.timelineToggle(row.track.id, toggles[index]) }
    }

    fileprivate var rowsForHeader: [(Track, CGFloat, CGFloat)] { rows.map { ($0.track, $0.y - scrollY, $0.height) } }
    fileprivate var visibleRange: (Double, Double) { (scrollSeconds, scrollSeconds + visibleSeconds) }
    fileprivate var frameRate: FrameRate { timeline?.canvas.frameRate ?? .fps30 }
}

// MARK: - Item layer

/// One timeline item: rounded body, label, filmstrip tiles, waveform, selection ring.
final class ItemLayer: CALayer {
    private let label = CATextLayer()
    private let filmstrip = CALayer()
    private let wave = CAShapeLayer()
    private var tiles: [CALayer] = []

    static func color(_ kind: TrackKind) -> NSColor {
        switch kind {
        case .video: NSColor(red: 0.20, green: 0.38, blue: 0.70, alpha: 1)
        case .overlay: NSColor(red: 0.42, green: 0.30, blue: 0.68, alpha: 1)
        case .title: NSColor(red: 0.72, green: 0.45, blue: 0.16, alpha: 1)
        case .caption: NSColor(red: 0.60, green: 0.52, blue: 0.14, alpha: 1)
        case .audio: NSColor(red: 0.16, green: 0.52, blue: 0.40, alpha: 1)
        case .music: NSColor(red: 0.12, green: 0.45, blue: 0.52, alpha: 1)
        }
    }

    override init() {
        super.init()
        cornerRadius = 4
        masksToBounds = true
        borderColor = NSColor.white.cgColor
        filmstrip.masksToBounds = true
        addSublayer(filmstrip)
        wave.fillColor = NSColor.white.withAlphaComponent(0.55).cgColor
        addSublayer(wave)
        label.fontSize = 11
        label.contentsScale = 2
        label.foregroundColor = NSColor.white.cgColor
        label.truncationMode = .end
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        addSublayer(label)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    func apply(item: Item, kind: TrackKind, selected: Bool, dimmed: Bool) {
        backgroundColor = Self.color(kind).cgColor
        borderWidth = selected ? 2 : 0
        opacity = dimmed ? 0.45 : 1
        var text = item.name
        switch item.content {
        case .caption(let c): text = c.text
        case .text(let t): text = t.text
        default: break
        }
        if item.locked { text = "🔒 " + text }
        if (label.string as? String) != text { label.string = text }
        label.isHidden = bounds.width < 30
        label.frame = CGRect(x: 5, y: 2, width: max(0, bounds.width - 10), height: 14)
        filmstrip.frame = CGRect(x: 0, y: 16, width: bounds.width, height: bounds.height - 16)
        wave.frame = CGRect(x: 0, y: kind.isVisual ? bounds.height - 18 : 16, width: bounds.width, height: kind.isVisual ? 18 : bounds.height - 16)
    }

    func setThumbnails(_ images: [CGImage?], tileWidth: CGFloat = 0) {
        while tiles.count < images.count {
            let t = CALayer(); t.contentsGravity = .resizeAspectFill; t.masksToBounds = true
            filmstrip.addSublayer(t); tiles.append(t)
        }
        for (i, t) in tiles.enumerated() {
            if i < images.count {
                t.isHidden = false
                t.frame = CGRect(x: CGFloat(i) * tileWidth, y: 0, width: tileWidth - 1, height: filmstrip.bounds.height)
                t.contents = images[i]
            } else { t.isHidden = true }
        }
    }

    func setWaveform(_ peaks: [(Float, Float)]?, columnWidth: CGFloat = 2) {
        guard let peaks, !peaks.isEmpty else { wave.path = nil; return }
        let h = wave.bounds.height, mid = h / 2
        let path = CGMutablePath()
        for (i, (lo, hi)) in peaks.enumerated() {
            let top = mid - CGFloat(hi) * mid, bottom = mid - CGFloat(lo) * mid
            path.addRect(CGRect(x: CGFloat(i) * columnWidth, y: top, width: columnWidth * 0.7, height: max(1, bottom - top)))
        }
        wave.path = path
    }
}

// MARK: - Ruler and headers

final class RulerView: NSView {
    weak var canvas: TimelineCanvas?
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let canvas, let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor(white: 0.16, alpha: 1).setFill()
        bounds.fill()
        let (start, end) = canvas.visibleRange
        let pps = canvas.pxPerSecond
        // Choose a tick step giving ≥ 70 pt between labels.
        let steps: [Double] = [1 / 30, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600]
        let step = steps.first { CGFloat($0) * pps >= 70 } ?? 3600
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                                                    .foregroundColor: NSColor(white: 0.75, alpha: 1)]
        ctx.setStrokeColor(NSColor(white: 0.45, alpha: 1).cgColor)
        var t = (start / step).rounded(.down) * step
        while t <= end {
            let x = canvas.x(for: t)
            if x >= TimelineCanvas.headerWidth {
                ctx.move(to: CGPoint(x: x, y: bounds.height - 9)); ctx.addLine(to: CGPoint(x: x, y: bounds.height)); ctx.strokePath()
                (Timecode.string(t, rate: canvas.frameRate, short: step >= 1) as NSString).draw(at: CGPoint(x: x + 3, y: 3), withAttributes: attrs)
                for k in 1..<4 {
                    let mx = canvas.x(for: t + step * Double(k) / 4)
                    ctx.move(to: CGPoint(x: mx, y: bounds.height - 4)); ctx.addLine(to: CGPoint(x: mx, y: bounds.height)); ctx.strokePath()
                }
            }
            t += step
        }
        // Playhead head.
        let px = canvas.x(for: canvas.playhead.seconds)
        if px >= TimelineCanvas.headerWidth {
            NSColor.systemRed.setFill()
            let p = NSBezierPath()
            p.move(to: CGPoint(x: px - 6, y: bounds.height - 12)); p.line(to: CGPoint(x: px + 6, y: bounds.height - 12))
            p.line(to: CGPoint(x: px, y: bounds.height)); p.close(); p.fill()
        }
        NSColor(white: 0.12, alpha: 1).setFill()
        CGRect(x: 0, y: 0, width: TimelineCanvas.headerWidth, height: bounds.height).fill()
        (Timecode.string(canvas.playhead.seconds, rate: canvas.frameRate) as NSString)
            .draw(at: CGPoint(x: 8, y: 5), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                                                             .foregroundColor: NSColor.white])
    }

    override func mouseDown(with event: NSEvent) { canvas?.mouseDown(with: event) }
    override func mouseDragged(with event: NSEvent) { canvas?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { canvas?.mouseUp(with: event) }
}

final class HeaderView: NSView {
    weak var canvas: TimelineCanvas?
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let canvas else { return }
        NSColor(white: 0.14, alpha: 1).setFill()
        bounds.fill()
        let nameAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white]
        let iconAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11)]
        for (track, y, h) in canvas.rowsForHeader {
            ItemLayer.color(track.kind).withAlphaComponent(0.9).setFill()
            CGRect(x: 0, y: y, width: 4, height: h).fill()
            (track.name as NSString).draw(at: CGPoint(x: 10, y: y + 5), withAttributes: nameAttrs)
            let icons = [track.hidden ? "◌" : "👁", track.muted ? "🔇" : "🔊", track.locked ? "🔒" : "🔓"]
            for (i, icon) in icons.enumerated() {
                let show = (i == 0 && track.kind.isVisual) || (i == 1 && track.kind.hasAudio) || i == 2
                if show { (icon as NSString).draw(at: CGPoint(x: bounds.width - 66 + CGFloat(i) * 22, y: y + h / 2 - 8), withAttributes: iconAttrs) }
            }
            NSColor(white: 0.2, alpha: 1).setFill()
            CGRect(x: 0, y: y + h + 0.5, width: bounds.width, height: 1).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        canvas?.headerClicked(at: convert(event.locationInWindow, from: nil))
    }
}

enum Timecode {
    /// HH:MM:SS:FF (or M:SS when `short`).
    static func string(_ seconds: Double, rate: FrameRate, short: Bool = false) -> String {
        let s = max(0, seconds)
        let total = Int(s)
        let frames = Int(((s - Double(total)) * rate.fps).rounded(.down))
        if short { return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
                                        : String(format: "%d:%02d", total / 60, total % 60) }
        return String(format: "%02d:%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60, frames)
    }
}
