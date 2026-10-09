import Foundation

public struct ValidationIssue: Sendable, Equatable, CustomStringConvertible {
    public enum Severity: Sendable { case error, warning }
    public var severity: Severity
    public var message: String
    public var item: ItemID?
    public var description: String { "\(severity == .error ? "error" : "warning"): \(message)" }
}

extension Timeline {
    /// Structural invariants every edit and every draft pass must preserve.
    public func validate(assetDurations: [AssetID: RationalTime] = [:]) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        func err(_ m: String, _ id: ItemID? = nil) { issues.append(.init(severity: .error, message: m, item: id)) }
        func warn(_ m: String, _ id: ItemID? = nil) { issues.append(.init(severity: .warning, message: m, item: id)) }

        var seen = Set<ItemID>()
        for track in tracks {
            for (a, b) in zip(track.items, track.items.dropFirst()) {
                if b.start < a.start { err("\(track.name): items out of order", b.id) }
                if a.range.overlaps(b.range) { err("\(track.name): '\(a.name)' overlaps '\(b.name)'", b.id) }
            }
            for item in track.items {
                if !seen.insert(item.id).inserted { err("duplicate item id \(item.id)", item.id) }
                if item.range.isEmpty { err("'\(item.name)' has no duration", item.id) }
                if item.start < .zero { err("'\(item.name)' starts before 0", item.id) }
                switch item.content {
                case .media(let m):
                    if m.source.start < .zero { err("'\(item.name)' source starts before media", item.id) }
                    if let d = assetDurations[m.asset], m.source.end > d + RationalTime(value: 1, scale: 1000) {
                        err("'\(item.name)' source ends past media (\(m.source.end.seconds) > \(d.seconds))", item.id)
                    }
                    let expected = item.range.duration.seconds * m.speed
                    if abs(m.source.duration.seconds - expected) > 0.002 {
                        err("'\(item.name)' source/timeline duration mismatch", item.id)
                    }
                    if !track.kind.hasAudio && !track.kind.isVisual { warn("media on \(track.kind) track", item.id) }
                case .caption(let c):
                    if c.words.contains(where: { $0.start < .zero || $0.end > item.range.duration + RationalTime(value: 1, scale: 100) }) {
                        warn("'\(item.name)' caption words fall outside the item", item.id)
                    }
                    if styles[c.style] == nil { warn("unknown caption style '\(c.style)'", item.id) }
                case .text(let t):
                    if styles[t.style] == nil { warn("unknown text style '\(t.style)'", item.id) }
                default: break
                }
            }
        }
        return issues
    }

    public var isValid: Bool { !validate().contains { $0.severity == .error } }
}
