import ClipperCore
import Foundation

/// Built-in styles and templates. Defined in Swift so they are type-checked; `clipper templates export` writes them
/// as JSON for users to copy and edit.
public enum BuiltIns {
    // MARK: Styles

    public static let styles: [String: TextStyle] = [
        // Short-form "hook" captions: heavy caps, 3 words a page, yellow active word, green keywords, pop-in.
        "bold-pop": TextStyle(font: "AvenirNext-Heavy", size: 0.052, color: .white, stroke: .black, strokeWidth: 0.09,
                              uppercase: true, maxWidth: 0.82, position: NormPoint(0.5, 0.68),
                              highlight: .init(color: RGBA(hex: "#FFD60A")), emphasisColor: RGBA(hex: "#4ADE80"),
                              animation: .pop, wordsPerPage: 3, maxLines: 2),
        // Readable subtitles: sentence case on a translucent box, line by line.
        "clean-subtitle": TextStyle(font: "HelveticaNeue-Medium", size: 0.034, color: .white, shadow: nil,
                                    box: .init(color: RGBA(0, 0, 0, 0.6), padding: 0.35, cornerRadius: 0.2),
                                    maxWidth: 0.86, position: NormPoint(0.5, 0.84), animation: .fade, wordsPerPage: 7, maxLines: 2),
        // Karaoke: the spoken word sits in a coloured box.
        "karaoke-box": TextStyle(font: "AvenirNext-Bold", size: 0.046, color: .white,
                                 maxWidth: 0.84, position: NormPoint(0.5, 0.7),
                                 highlight: .init(color: .white, box: RGBA(hex: "#7C3AED")), animation: .none, wordsPerPage: 5),
        "title-bold": TextStyle(font: "AvenirNext-Heavy", size: 0.05, color: .white, shadow: nil,
                                box: .init(color: RGBA(0, 0, 0, 0.55), padding: 0.35, cornerRadius: 0.25),
                                maxWidth: 0.84, position: NormPoint(0.5, 0.13), wordsPerPage: 99, maxLines: 3),
        "title-clean": TextStyle(font: "HelveticaNeue-Bold", size: 0.045, color: .white, maxWidth: 0.84,
                                 position: NormPoint(0.5, 0.15), wordsPerPage: 99, maxLines: 3),
    ]

    public static let captionStyles = ["bold-pop", "clean-subtitle", "karaoke-box"]

    // MARK: Templates

    static func title(_ style: String, seconds: Double) -> TemplateElement {
        TemplateElement(id: "title", track: .title, content: .text(TextContent(text: "{title}", style: style)),
                        timing: .opening(seconds: seconds), fadeIn: 0.15, fadeOut: 0.3)
    }

    public static let talkingHead = Template(
        id: "talking-head", name: "Talking head", summary: "One speaker, tight cuts, bold captions, jump-cut zooms, music ducked under speech.",
        contentType: .talkingHead, canvas: Canvas(width: 1080, height: 1920, frameRate: .fps30),
        slots: [Slot(id: "speaker", name: "Speaker", role: .primary, reframe: .face)],
        elements: [title("title-bold", seconds: 2.5)],
        rules: Rules(maxDuration: 60, silenceCut: SilenceCutRule(minGap: 0.35), punchIn: PunchInRule(zoom: 1.12, minSpacing: 4),
                     captions: CaptionRule(style: "bold-pop"), duck: DuckRule(depth: 14)),
        music: MusicPolicy(moods: ["chill", "upbeat", "inspiring"], minBPM: 80, maxBPM: 125, gain: -22))

    public static let gameplay = Template(
        id: "gameplay", name: "Gameplay + facecam",
        summary: "Gameplay with commentary in the bottom 60%, optional facecam on top (cut in sync). Without a facecam the gameplay fills the frame.",
        contentType: .gameplay, canvas: Canvas(width: 1080, height: 1920, frameRate: .fps60),
        slots: [
            Slot(id: "gameplay", name: "Gameplay", role: .primary,
                 transform: Transform(box: NormSize(1, 0.6), position: .constant(NormPoint(0.5, 0.7))),
                 aloneTransform: .fullFrame),
            Slot(id: "facecam", name: "Facecam", role: .secondary, fill: .linked,
                 transform: Transform(box: NormSize(1, 0.4), position: .constant(NormPoint(0.5, 0.2))),
                 reframe: .face, useAudio: false, optional: true),
        ],
        elements: [title("title-bold", seconds: 2.5)],
        rules: Rules(maxDuration: 60, silenceCut: SilenceCutRule(minGap: 0.5, padBefore: 0.1, padAfter: 0.2),
                     captions: CaptionRule(style: "gameplay-caption"), duck: DuckRule(depth: 10)),
        styles: ["gameplay-caption": {
            var s = BuiltIns.styles["karaoke-box"]!
            s.position = NormPoint(0.5, 0.4)   // on the split line between facecam and gameplay
            return s
        }()],
        music: MusicPolicy(moods: ["energetic", "electronic", "intense"], gain: -26))

    public static let montage = Template(
        id: "montage", name: "Montage", summary: "Clips cut on the beat of the music, no voice. Great for highlights and travel reels.",
        contentType: .montage, canvas: Canvas(width: 1080, height: 1920, frameRate: .fps30),
        slots: [Slot(id: "clips", name: "Clips", role: .primary, useAudio: false)],
        elements: [title("title-bold", seconds: 2)],
        rules: Rules(maxDuration: 30, beatCut: BeatCutRule(everyBeats: 4, minClip: 0.8)),
        music: MusicPolicy(moods: ["upbeat", "energetic", "happy"], minBPM: 90, maxBPM: 140, gain: -4, fadeIn: 0, fadeOut: 1.5))

    public static let vlog = Template(
        id: "vlog", name: "Vlog / travel", summary: "Talking moments and B-roll, gentle pause removal, clean subtitles, warm music.",
        contentType: .vlog, canvas: Canvas(width: 1080, height: 1920, frameRate: .fps30),
        slots: [Slot(id: "footage", name: "Footage", role: .primary, reframe: .face)],
        elements: [title("title-clean", seconds: 3)],
        rules: Rules(maxDuration: 90, silenceCut: SilenceCutRule(minGap: 0.7, padBefore: 0.15, padAfter: 0.25),
                     captions: CaptionRule(style: "clean-subtitle"), duck: DuckRule(depth: 10), maxSilentClip: 4),
        music: MusicPolicy(moods: ["inspiring", "chill", "happy", "cinematic"], gain: -18))

    public static let templates: [Template] = [talkingHead, gameplay, montage, vlog]

    public static func template(_ id: String) -> Template? { templates.first { $0.id == id } }
}
