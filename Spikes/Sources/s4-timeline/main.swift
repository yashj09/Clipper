// S4: can an AppKit + CALayer timeline stay smooth at pro-NLE scale?
// 8 tracks × 250 items = 2,000 items with filmstrip thumbnails, waveforms and labels. Layers are virtualized:
// only visible items get a layer from a reuse pool. A display link drives automatic pan + zoom (including a
// fully zoomed-out pass where every item is on screen) and we measure frame pacing and per-frame update cost.
// Pass: ≥ 58 fps average, < 2% long frames (> 1.5× refresh interval). Update p99 < 4 ms is a stretch goal
// (half a 120 Hz frame); hiding pooled layers instead of removing them was tried and was slower.
import AppKit
import QuartzCore
import SpikeKit

struct Item { let start: Double; let duration: Double; let kind: Int; let title: String }

final class TimelineView: NSView {
    let trackCount = 8, itemsPerTrack = 250, trackHeight: CGFloat = 64, headerWidth: CGFloat = 120
    var tracks: [[Item]] = []
    var pxPerSecond: CGFloat = 40
    var scrollSeconds: Double = 0
    var totalSeconds: Double = 0

    private var pool: [CALayer] = []
    private var active: [Int: CALayer] = [:]   // key = track * 100_000 + index
    private let thumbs: [CGImage]
    private let waveform: CGImage
    private let colors: [CGColor] = [NSColor.systemBlue, .systemPurple, .systemTeal, .systemGreen].map(\.cgColor)

    private var summaries: [CALayer] = []         // level-of-detail: one pre-rendered strip per track
    private var summaryScale: CGFloat = 0
    private var link: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private var lastTimestamp: CFTimeInterval = 0
    var frameDeltas: [Double] = [], updateTimes: [Double] = [], visibleCounts: [Int] = []
    var targetInterval: Double = 1.0 / 60
    let runSeconds = 8.0
    var onFinish: (() -> Void)?

    override init(frame: NSRect) {
        thumbs = (0..<6).map { Self.makeThumb(hue: CGFloat($0) / 6) }
        waveform = Self.makeWaveform()
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        var rng = SystemRandomNumberGenerator()
        for t in 0..<trackCount {
            var cursor = 0.0, items: [Item] = []
            for i in 0..<itemsPerTrack {
                let d = Double.random(in: 1...8, using: &rng)
                items.append(Item(start: cursor, duration: d, kind: t < 4 ? 0 : (t < 6 ? 1 : 2), title: "Clip \(t)-\(i)"))
                cursor += d + (Bool.random() ? 0 : Double.random(in: 0...1.5))
            }
            totalSeconds = max(totalSeconds, cursor)
            tracks.append(items)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func start() {
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc func tick(_ link: CADisplayLink) {
        if startTime == 0 { startTime = link.timestamp; lastTimestamp = link.timestamp
            targetInterval = link.targetTimestamp - link.timestamp }
        else { frameDeltas.append(link.timestamp - lastTimestamp); lastTimestamp = link.timestamp }
        let t = link.timestamp - startTime
        // 0–3 s: pan at normal zoom · 3–5.5 s: zoom out to show the whole timeline · 5.5–8 s: zoom back in while panning.
        let fitAll = Double(bounds.width - headerWidth) / totalSeconds
        if t < 3 { pxPerSecond = 40; scrollSeconds = t * 60 }
        else if t < 5.5 { let u = (t - 3) / 2.5; pxPerSecond = CGFloat(exp(log(40) + (log(fitAll) - log(40)) * u)); scrollSeconds = 180 * (1 - u) }
        else { let u = (t - 5.5) / 2.5; pxPerSecond = CGFloat(exp(log(fitAll) + (log(80) - log(fitAll)) * u)); scrollSeconds = u * 400 }
        let t0 = CACurrentMediaTime()
        layoutItems()
        updateTimes.append(CACurrentMediaTime() - t0)
        if t > runSeconds { link.invalidate(); onFinish?() }
    }

    func layoutItems() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // LOD: when an average item would be < 16 px wide, show per-track summary strips instead of item layers.
        let avgItemPx = pxPerSecond * CGFloat(totalSeconds / Double(itemsPerTrack))
        if avgItemPx < 16 {
            if summaries.isEmpty { buildSummaries() }
            for (key, l) in active { l.removeFromSuperlayer(); pool.append(l); active[key] = nil }
            for (ti, sl) in summaries.enumerated() {
                sl.isHidden = false
                sl.frame = CGRect(x: headerWidth - CGFloat(scrollSeconds) * pxPerSecond, y: CGFloat(ti) * (trackHeight + 2) + 4,
                                  width: CGFloat(totalSeconds) * pxPerSecond, height: trackHeight)
            }
            visibleCounts.append(0)
            return
        }
        summaries.forEach { $0.isHidden = true }
        let visibleStart = scrollSeconds, visibleEnd = scrollSeconds + Double((bounds.width - headerWidth) / pxPerSecond)
        var keep = Set<Int>()
        for (ti, items) in tracks.enumerated() {
            // Binary search for the first item ending after visibleStart.
            var lo = 0, hi = items.count
            while lo < hi { let m = (lo + hi) / 2; if items[m].start + items[m].duration < visibleStart { lo = m + 1 } else { hi = m } }
            var i = lo
            while i < items.count, items[i].start < visibleEnd {
                let key = ti * 100_000 + i
                keep.insert(key)
                let item = items[i]
                let l = active[key] ?? dequeue(for: item, key: key)
                let x = headerWidth + CGFloat(item.start - scrollSeconds) * pxPerSecond
                let w = max(1, CGFloat(item.duration) * pxPerSecond - 1)
                l.frame = CGRect(x: x, y: CGFloat(ti) * (trackHeight + 2) + 4, width: w, height: trackHeight)
                decorate(l, item: item, width: w)
                i += 1
            }
        }
        for (key, l) in active where !keep.contains(key) { l.removeFromSuperlayer(); pool.append(l); active[key] = nil }
        visibleCounts.append(keep.count)
    }

    /// Renders each track once into an image (1 px ≈ 1 s); scaled by Core Animation while zoomed out.
    private func buildSummaries() {
        let width = Int(totalSeconds.rounded(.up))
        for (ti, items) in tracks.enumerated() {
            let ctx = CGContext(data: nil, width: width, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
            ctx.setFillColor(colors[items[0].kind % colors.count])
            for it in items { ctx.fill(CGRect(x: it.start, y: 0, width: max(it.duration - 0.2, 0.5), height: 8)) }
            let l = CALayer()
            l.contents = ctx.makeImage(); l.contentsGravity = .resize; l.magnificationFilter = .nearest
            layer!.addSublayer(l)
            summaries.append(l)
        }
    }

    private func dequeue(for item: Item, key: Int) -> CALayer {
        let l = pool.popLast() ?? makeItemLayer()
        layer!.addSublayer(l)
        active[key] = l
        (l.sublayers?[2] as? CATextLayer)?.string = item.title
        l.sublayers?[0].contents = nil; l.sublayers?[1].contents = nil
        l.backgroundColor = colors[item.kind % colors.count]
        return l
    }

    private func makeItemLayer() -> CALayer {
        let l = CALayer()
        l.cornerRadius = 4; l.masksToBounds = true
        let strip = CALayer()            // filmstrip: one thumbnail tiled horizontally via contentsRect
        strip.contentsGravity = .resize
        strip.autoresizingMask = [.layerWidthSizable]   // Core Animation resizes with the item; no per-frame work
        let wave = CALayer()             // waveform image
        wave.contentsGravity = .resize
        wave.autoresizingMask = [.layerWidthSizable]
        let text = CATextLayer()
        text.fontSize = 11; text.foregroundColor = .white; text.contentsScale = 2
        l.sublayers = [strip, wave, text]
        return l
    }

    private func decorate(_ l: CALayer, item: Item, width: CGFloat) {
        guard let subs = l.sublayers, subs.count == 3 else { return }
        let (strip, wave, text) = (subs[0], subs[1], subs[2] as! CATextLayer)
        let detailed = width > 24                       // skip decorations on tiny items (LOD)
        let showStrip = detailed && item.kind == 0, showWave = detailed && item.kind != 0, showText = width >= 60
        if strip.isHidden == showStrip { strip.isHidden = !showStrip }
        if wave.isHidden == showWave { wave.isHidden = !showWave }
        if text.isHidden == showText { text.isHidden = !showText }
        if showStrip {
            if strip.contents == nil {
                strip.frame = CGRect(x: 0, y: 16, width: width, height: trackHeight - 16)
                strip.contents = thumbs[Int(item.start) % thumbs.count]
            }
            let tiles = (max(1, width / 80)).rounded(.up)   // one thumb per ~80 px; only touch when the count changes
            if strip.contentsRect.width != tiles { strip.contentsRect = CGRect(x: 0, y: 0, width: tiles, height: 1) }
        }
        if showWave, wave.contents == nil {
            wave.frame = CGRect(x: 0, y: 16, width: width, height: trackHeight - 16)
            wave.contents = waveform
        }
        if showText, text.frame.width != (width - 8).rounded() { text.frame = CGRect(x: 4, y: 1, width: (width - 8).rounded(), height: 14) }
    }

    static func makeThumb(hue: CGFloat) -> CGImage {
        let ctx = CGContext(data: nil, width: 160, height: 96, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.setFillColor(NSColor(hue: hue, saturation: 0.6, brightness: 0.8, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 160, height: 96))
        ctx.setFillColor(NSColor(white: 1, alpha: 0.5).cgColor)
        ctx.fillEllipse(in: CGRect(x: 50, y: 20, width: 60, height: 60))
        ctx.setStrokeColor(NSColor.black.cgColor); ctx.stroke(CGRect(x: 0, y: 0, width: 160, height: 96), width: 2)
        return ctx.makeImage()!
    }

    static func makeWaveform() -> CGImage {
        let w = 4000, h = 96
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.setFillColor(NSColor(white: 1, alpha: 0.75).cgColor)
        for x in stride(from: 0, to: w, by: 2) {
            let a = abs(sin(Double(x) / 37) * sin(Double(x) / 211)) * Double(h / 2 - 4) + 2
            ctx.fill(CGRect(x: Double(x), y: Double(h) / 2 - a, width: 1.5, height: a * 2))
        }
        return ctx.makeImage()!
    }
}

func percentile(_ v: [Double], _ p: Double) -> Double { let s = v.sorted(); return s.isEmpty ? 0 : s[min(s.count - 1, Int(p * Double(s.count)))] }

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 80, y: 120, width: 1600, height: 620), styleMask: [.titled, .closable],
                      backing: .buffered, defer: false)
window.title = "Clipper S4 — timeline perf spike (auto-closes)"
let view = TimelineView(frame: window.contentLayoutRect)
window.contentView = view
window.makeKeyAndOrderFront(nil)
app.activate()
print("S4 — AppKit/CALayer timeline: 8 tracks, \(view.tracks.map(\.count).reduce(0, +)) items, \(Int(view.totalSeconds))s")
view.onFinish = {
    let d = view.frameDeltas.dropFirst(5).map { $0 }
    let fps = Double(d.count) / d.reduce(0, +)
    let refresh = 1 / view.targetInterval
    let long = d.filter { $0 > view.targetInterval * 1.5 }.count
    let longPct = Double(long) / Double(max(d.count, 1)) * 100
    let up50 = percentile(view.updateTimes, 0.5) * 1000, up99 = percentile(view.updateTimes, 0.99) * 1000
    print(String(format: "  display refresh %.0f Hz · achieved %.1f fps · long frames %d/%d (%.1f%%)", refresh, fps, long, d.count, longPct))
    print(String(format: "  update cost p50 %.2f ms · p99 %.2f ms · max %.2f ms · max visible items %d",
                 up50, up99, (view.updateTimes.max() ?? 0) * 1000, view.visibleCounts.max() ?? 0))
    Spike.verdict("S4 smoothness", fps >= 58 && longPct < 2, String(format: "%.1f fps, %.1f%% long frames", fps, longPct))
    Spike.verdict("S4 update budget", up99 < 4, String(format: "p99 %.2f ms per frame (budget 4 ms)", up99))
    Spike.writeResult("s4", ["refreshHz": refresh, "fps": fps, "longFramePct": longPct, "updateP50ms": up50, "updateP99ms": up99,
                             "maxVisible": view.visibleCounts.max() ?? 0])
    exit(0)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { view.start() }
app.run()
