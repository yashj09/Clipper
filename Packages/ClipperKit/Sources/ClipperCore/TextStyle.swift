import Foundation

/// Visual style for titles and captions. Sizes are fractions of the canvas so styles work at any resolution.
public struct TextStyle: Codable, Sendable, Equatable {
    public enum Alignment: String, Codable, Sendable { case left, center, right }
    /// How caption words appear and how the active word is shown.
    public enum Animation: String, Codable, Sendable {
        case none
        /// Page appears with a quick scale-up.
        case pop
        case fade
        /// Words appear one by one as they are spoken.
        case wordByWord
    }

    public struct Shadow: Codable, Sendable, Equatable {
        public var color: RGBA
        /// Blur radius as a fraction of the font size.
        public var radius: Double
        public var offset: NormPoint
        public init(color: RGBA = RGBA(0, 0, 0, 0.6), radius: Double = 0.08, offset: NormPoint = NormPoint(0, 0.04)) {
            self.color = color; self.radius = radius; self.offset = offset
        }
    }

    public struct Box: Codable, Sendable, Equatable {
        public var color: RGBA
        /// Padding as a fraction of the font size.
        public var padding: Double
        /// Corner radius as a fraction of the font size.
        public var cornerRadius: Double
        public init(color: RGBA, padding: Double = 0.3, cornerRadius: Double = 0.25) {
            self.color = color; self.padding = padding; self.cornerRadius = cornerRadius
        }
    }

    /// Styling of the word currently being spoken (captions only).
    public struct Highlight: Codable, Sendable, Equatable {
        public var color: RGBA?
        public var box: RGBA?
        /// Scale of the active word (1 = none).
        public var scale: Double
        public init(color: RGBA? = nil, box: RGBA? = nil, scale: Double = 1) { self.color = color; self.box = box; self.scale = scale }
    }

    /// PostScript font name; falls back to the system font if unavailable.
    public var font: String
    /// Font size as a fraction of the canvas height.
    public var size: Double
    public var color: RGBA
    public var stroke: RGBA?
    /// Stroke width as a fraction of the font size.
    public var strokeWidth: Double
    public var shadow: Shadow?
    public var box: Box?
    public var alignment: Alignment
    public var uppercase: Bool
    /// Maximum line width as a fraction of the canvas width (text wraps beyond it).
    public var maxWidth: Double
    public var lineSpacing: Double
    /// Default anchor (centre of the text block) when an item doesn't override its position.
    public var position: NormPoint
    public var highlight: Highlight?
    /// Colour for emphasized words (e.g. keywords).
    public var emphasisColor: RGBA?
    public var animation: Animation
    /// Caption paging: maximum words per page and lines per page.
    public var wordsPerPage: Int
    public var maxLines: Int

    public init(font: String = "Helvetica-Bold", size: Double = 0.045, color: RGBA = .white, stroke: RGBA? = nil,
                strokeWidth: Double = 0, shadow: Shadow? = Shadow(), box: Box? = nil, alignment: Alignment = .center,
                uppercase: Bool = false, maxWidth: Double = 0.84, lineSpacing: Double = 1.1,
                position: NormPoint = NormPoint(0.5, 0.75), highlight: Highlight? = nil, emphasisColor: RGBA? = nil,
                animation: Animation = .none, wordsPerPage: Int = 6, maxLines: Int = 2) {
        self.font = font; self.size = size; self.color = color; self.stroke = stroke; self.strokeWidth = strokeWidth
        self.shadow = shadow; self.box = box; self.alignment = alignment; self.uppercase = uppercase
        self.maxWidth = maxWidth; self.lineSpacing = lineSpacing; self.position = position; self.highlight = highlight
        self.emphasisColor = emphasisColor; self.animation = animation; self.wordsPerPage = wordsPerPage; self.maxLines = maxLines
    }
}
