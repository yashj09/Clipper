import ClipperCore
import Foundation

/// Cover frames for an edited timeline: the clips' visual samples scored as `CoverFramePicker` scores them, at the
/// timeline times where the primary track shows them.
public enum TimelineCover {
    /// Added when a caption page is on screen: the frame carries the video's words.
    static let captionWeight = 0.3

    /// The best `count` timeline moments, best first, at least `CoverFramePicker.spacing` apart. Skips the first and
    /// last half second and frames inside a transition.
    public static func pick(timeline: Timeline, analyses: [AssetID: AssetAnalysis], count: Int) -> [CoverCandidate] {
        let duration = timeline.duration.seconds
        let visual = timeline.tracks.filter { $0.kind.isVisual && !$0.hidden }
        let transitions = visual.flatMap(\.items).compactMap { item in
            item.transition.map { item.start.seconds..<(item.start + $0.duration).seconds }
        }
        let captions = visual.filter { $0.kind == .caption }.flatMap(\.items).filter(\.enabled).map { $0.start.seconds..<$0.end.seconds }
        let primary = timeline.tracks.first { $0.kind == .video }?.items.filter(\.enabled) ?? []

        var scored: [CoverCandidate] = []
        for item in primary {
            guard let ref = item.content.mediaRef, let analysis = analyses[ref.asset] else { continue }
            let faceTimes = analysis.faces?.samples.map(\.time) ?? []
            let source = ref.source.start.seconds..<ref.source.end.seconds
            for sample in analysis.visual?.samples ?? [] where source.contains(sample.time) {
                let t = item.start.seconds + (sample.time - source.lowerBound) / ref.speed
                guard t >= CoverFramePicker.margin, t <= duration - CoverFramePicker.margin,
                      !transitions.contains(where: { $0.contains(t) }) else { continue }
                var candidate = CoverFramePicker.score(sample, faceTimes: faceTimes)
                candidate.time = t
                if captions.contains(where: { $0.contains(t) }) {
                    candidate.score += captionWeight
                    candidate.reasons.append("caption")
                }
                scored.append(candidate)
            }
        }
        return CoverFramePicker.best(scored, count: count)
    }
}
