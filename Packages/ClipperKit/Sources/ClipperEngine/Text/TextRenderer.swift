import ClipperCore
import CoreGraphics
import CoreText
import Foundation

/// Laid-out text block: words wrapped into lines, with each word's rectangle (pixels, y down, relative to the image).
public struct TextLayout: Sendable {
    public struct Word: Sendable { public var text: String; public var rect: CGRect; public var line: Int }
    public var size: CGSize
    public var words: [Word]
    public var lines: [CGRect]
}

/// Renders titles and caption pages with Core Text into premultiplied BGRA images.
/// Sizes come from `TextStyle` fractions × canvas, so output is resolution-independent.
public enum TextRenderer {
    public struct Options: Hashable, Sendable {
        /// Caption word currently spoken (highlighted), if any.
        public var activeWord: Int?
        /// Words after this index are hidden (word-by-word reveal), if set.
        public var revealUpTo: Int?
        public init(activeWord: Int? = nil, revealUpTo: Int? = nil) { self.activeWord = activeWord; self.revealUpTo = revealUpTo }
    }

    static func font(_ style: TextStyle, canvasHeight: Int) -> CTFont {
        let px = max(4, style.size * Double(canvasHeight))
        return CTFontCreateWithName(style.font as CFString, px, nil)
    }

    static func padding(_ style: TextStyle, fontSize: Double) -> Double {
        var p = fontSize * 0.2
        if let box = style.box { p += fontSize * box.padding }
        if let s = style.shadow { p += fontSize * (s.radius + max(abs(s.offset.x), abs(s.offset.y))) }
        p += fontSize * style.strokeWidth
        if let h = style.highlight, h.box != nil { p += fontSize * 0.15 }
        return p
    }

    /// Greedy word wrap within `style.maxWidth` of the canvas, capped at `style.maxLines` lines for captions.
    /// Right-to-left text (Hebrew, Arabic…) keeps its logical word order but places words right to left on each line;
    /// each word's own glyphs are shaped by Core Text.
    public static func layout(words input: [String], style: TextStyle, canvasWidth: Int, canvasHeight: Int) -> TextLayout {
        let font = font(style, canvasHeight: canvasHeight)
        let fontSize = CTFontGetSize(font)
        let words = input.map { style.uppercase ? $0.uppercased() : $0 }
        func width(_ s: String) -> Double {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.init(kCTFontAttributeName as String): font]))
            return CTLineGetTypographicBounds(line, nil, nil, nil)
        }
        let space = width(" ")
        let maxW = style.maxWidth * Double(canvasWidth)
        var lines: [[Int]] = [[]]
        var lineW: [Double] = [0]
        let wordW = words.map(width)
        for (i, w) in wordW.enumerated() {
            let add = lines[lines.count - 1].isEmpty ? w : lineW[lineW.count - 1] + space + w
            if add > maxW && !lines[lines.count - 1].isEmpty {
                lines.append([i]); lineW.append(w)
            } else {
                lines[lines.count - 1].append(i); lineW[lineW.count - 1] = add
            }
        }
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let lineHeight = (ascent + descent) * style.lineSpacing
        let pad = padding(style, fontSize: fontSize)
        let blockW = (lineW.max() ?? 0)
        let size = CGSize(width: ceil(blockW + pad * 2), height: ceil(Double(lines.count) * lineHeight + pad * 2 - (lineHeight - ascent - descent)))

        let rightToLeft = CaptionLanguage.startsRightToLeft(words.joined(separator: " "))
        var outWords: [TextLayout.Word] = Array(repeating: .init(text: "", rect: .zero, line: 0), count: words.count)
        var lineRects: [CGRect] = []
        for (li, idx) in lines.enumerated() {
            let lw = lineW[li]
            var x: Double
            switch style.alignment {
            case .left: x = pad
            case .center: x = pad + (blockW - lw) / 2
            case .right: x = pad + blockW - lw
            }
            let top = pad + Double(li) * lineHeight
            lineRects.append(CGRect(x: x, y: top, width: lw, height: ascent + descent))
            let lineStart = x
            for i in idx {
                let wx = rightToLeft ? lineStart + lw - (x - lineStart) - wordW[i] : x
                outWords[i] = .init(text: words[i], rect: CGRect(x: wx, y: top, width: wordW[i], height: ascent + descent), line: li)
                x += wordW[i] + space
            }
        }
        return TextLayout(size: size, words: outWords, lines: lineRects)
    }

    /// Renders a text block. `emphasis[i]` marks keyword words drawn in the style's emphasis colour.
    public static func render(words: [String], emphasis: [Bool] = [], style: TextStyle, canvasWidth: Int, canvasHeight: Int,
                              options: Options = Options()) -> CGImage? {
        let layout = layout(words: words, style: style, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        let w = max(Int(layout.size.width), 1), h = max(Int(layout.size.height), 1)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        // Flip so we can lay out top-down; Core Text draws with baseline origin, so text needs a local unflip.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)

        let font = font(style, canvasHeight: canvasHeight)
        let fontSize = CTFontGetSize(font)
        let descent = CTFontGetDescent(font)
        let visible: (Int) -> Bool = { i in options.revealUpTo.map { i <= $0 } ?? true }

        // Background boxes: one rounded box per line (only around visible words).
        if let box = style.box {
            ctx.setFillColor(box.color.cgColor)
            for (li, _) in layout.lines.enumerated() {
                let ws = layout.words.enumerated().filter { $0.element.line == li && visible($0.offset) }.map(\.element.rect)
                guard let first = ws.first else { continue }
                let r = ws.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -fontSize * box.padding, dy: -fontSize * box.padding * 0.6)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: fontSize * box.cornerRadius, cornerHeight: fontSize * box.cornerRadius, transform: nil))
                ctx.fillPath()
            }
        }
        // Active-word highlight box.
        if let active = options.activeWord, let hb = style.highlight?.box, active < layout.words.count, visible(active) {
            let r = layout.words[active].rect.insetBy(dx: -fontSize * 0.15, dy: -fontSize * 0.08)
            ctx.setFillColor(hb.cgColor)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: fontSize * 0.2, cornerHeight: fontSize * 0.2, transform: nil))
            ctx.fillPath()
        }

        for (i, word) in layout.words.enumerated() where visible(i) {
            var color = style.color
            if i < emphasis.count, emphasis[i], let e = style.emphasisColor { color = e }
            if i == options.activeWord, let hc = style.highlight?.color { color = hc }
            let baseline = CGPoint(x: word.rect.minX, y: word.rect.maxY - descent)
            ctx.saveGState()
            if let s = style.shadow {
                ctx.setShadow(offset: CGSize(width: s.offset.x * fontSize, height: -s.offset.y * fontSize),
                              blur: s.radius * fontSize, color: s.color.cgColor)
            }
            // Stroke pass first (outside stroke look), then fill on top.
            if let stroke = style.stroke, style.strokeWidth > 0 {
                draw(word.text, font: font, at: baseline, in: ctx, attrs: [
                    .init(kCTStrokeWidthAttributeName as String): style.strokeWidth * 100 * 2,
                    .init(kCTStrokeColorAttributeName as String): stroke.cgColor,
                ])
                ctx.setShadow(offset: .zero, blur: 0, color: nil)
            }
            draw(word.text, font: font, at: baseline, in: ctx, attrs: [.init(kCTForegroundColorAttributeName as String): color.cgColor])
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    private static func draw(_ s: String, font: CTFont, at p: CGPoint, in ctx: CGContext, attrs: [NSAttributedString.Key: Any]) {
        var a = attrs
        a[.init(kCTFontAttributeName as String)] = font
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: a))
        ctx.saveGState()
        // Undo the y-flip locally so glyphs aren't upside down.
        ctx.translateBy(x: p.x, y: p.y)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}

extension RGBA {
    public var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}
