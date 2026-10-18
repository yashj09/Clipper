import ClipperCore
import Foundation

/// Re-scores highlight candidates for short-form potential with a local LLM (`LocalLLM`). Without a server the
/// heuristic scores are used as they are.
public struct LocalLLMRanker: Sendable {
    public let endpoint: LLMEndpoint
    public let batchSize: Int
    let session: URLSession

    /// Weight of the model's opinion in the blended score; the heuristic gets the rest.
    static let llmWeight = 0.6
    /// Excerpts are cut to about this many characters to keep prompts small.
    static let maxExcerpt = 1200
    static let maxTitle = 60

    public init(endpoint: LLMEndpoint, batchSize: Int = 20, session: URLSession = .shared) {
        self.endpoint = endpoint; self.batchSize = max(1, batchSize); self.session = session
    }

    /// True if the server answers GET {base}/models (and lists the model, if it lists any). Fast (≤ 2 s timeout).
    public func isAvailable() async -> Bool { await LocalLLM(endpoint: endpoint, session: session).isAvailable() }

    /// Lists model ids from GET {base}/models.
    public func models() async throws -> [String] { try await LocalLLM(endpoint: endpoint, session: session).models() }

    // MARK: Ranking

    /// Re-scores candidates for short-form potential. Returns the same candidates (same start/end) with `score` replaced
    /// by a blend: 0.6 × LLM score (0–10 → 0–1) + 0.4 × incoming heuristic score, `title` set to a short hook
    /// (≤ 60 chars) and `reason` prefixed with the model's one-line reason. Candidates the model omitted keep their
    /// heuristic score. Sorted by score desc.
    public func rank(_ candidates: [Highlight], context: String? = nil,
                     progress: (@Sendable (Double) -> Void)? = nil) async throws -> [Highlight] {
        if let why = endpoint.nonLocalReason { throw LLMRankerError.notLocal(why) }
        guard !candidates.isEmpty else { progress?(1); return [] }
        progress?(0)
        let llm = LocalLLM(endpoint: endpoint, session: session)
        var result = candidates
        var start = 0
        while start < candidates.count {
            try Task.checkCancellation()
            let end = min(start + batchSize, candidates.count)
            let batch = Array(candidates[start..<end])
            let rankings = try await rankBatch(batch, context: context, llm: llm)
            for (i, r) in rankings {
                guard batch.indices.contains(i) else { continue }
                result[start + i] = Self.apply(r, to: batch[i])
            }
            start = end
            progress?(Double(end) / Double(candidates.count))
        }
        // Stable: equal scores keep their incoming order.
        return result.enumerated()
            .sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
            .map(\.element)
    }

    static func apply(_ r: LLMRanking, to h: Highlight) -> Highlight {
        var out = h
        let llm = min(max(r.score, 0), 10) / 10
        out.score = llmWeight * llm + (1 - llmWeight) * h.score
        out.signals["llm"] = llm
        if let title = r.title.map(cleanTitle), !title.isEmpty { out.title = title }
        if let reason = r.reason.map(oneLine), !reason.isEmpty {
            out.reason = h.reason.isEmpty ? reason : "\(reason) — \(h.reason)"
        }
        return out
    }

    static func oneLine(_ s: String) -> String {
        let line = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cleanTitle(_ s: String) -> String {
        var t = oneLine(s).trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’ "))
        // Small models sometimes answer "..." or similar filler; a title needs actual words.
        guard t.contains(where: { $0.isLetter || $0.isNumber }) else { return "" }
        if t.count > maxTitle {
            let cut = t.prefix(maxTitle - 1)
            let word = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
            t = (word.count >= maxTitle / 2 ? String(word) : String(cut))
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) + "…"
        }
        return t
    }

    /// One chat completion for a batch; ids in the prompt are 1-based positions in `batch`.
    /// Returns rankings keyed by 0-based batch index.
    private func rankBatch(_ batch: [Highlight], context: String?, llm: LocalLLM) async throws -> [Int: LLMRanking] {
        let rankings = try await llm.complete(system: Self.systemPrompt, user: Self.userMessage(for: batch, context: context),
                                              schema: Self.schema) { LLMResponseParser.rankings(from: $0) }
        var byIndex: [Int: LLMRanking] = [:]
        for r in rankings where (1...batch.count).contains(r.id) && byIndex[r.id - 1] == nil {
            byIndex[r.id - 1] = r
        }
        return byIndex
    }

    // MARK: Request building

    static var schema: [String: Any] {
        let item: [String: Any] = [
            "type": "object",
            "properties": [
                "id": ["type": "integer"],
                "score": ["type": "number", "minimum": 0, "maximum": 10],
                "title": ["type": "string"],
                "reason": ["type": "string"],
            ],
            "required": ["id", "score", "title", "reason"],
            "additionalProperties": false,
        ]
        return [
            "name": "highlight_rankings",
            "strict": true,
            "schema": [
                "type": "object",
                "properties": ["rankings": ["type": "array", "items": item]],
                "required": ["rankings"],
                "additionalProperties": false,
            ] as [String: Any],
        ]
    }

    static let systemPrompt = """
    You are an expert short-form video editor. Each candidate is a transcript excerpt cut from a long recording \
    (stream, podcast, VOD). Judge each one as a STANDALONE vertical short (TikTok / Reels / Shorts) watched by someone \
    who has never seen the source.

    Reward:
    - A strong hook in the first 3 seconds (a bold claim, question, surprise or conflict right away).
    - Being self-contained: it makes sense with no outside context.
    - A clear payoff: emotional, surprising, informative or funny.
    Penalize:
    - Starting mid-sentence or mid-thought, or ending before the payoff.
    - Dangling references to things outside the clip ("like I said", "that thing", "he" with no antecedent).
    - Rambling, filler, small talk, technical setup, dead air.

    `signals` are measured cues (loudness, laughter, speech rate, ...) normalized to 0–1; use them as hints only.
    Score every candidate from 0 (unusable) to 10 (would go viral). Use the full range and be discriminating.
    For each give a catchy title of at most 60 characters (no hashtags, no emoji) that works as on-screen hook text, \
    and a one-line reason.

    Reply with strict JSON only, no prose and no markdown:
    {"rankings":[{"id":1,"score":7.5,"title":"...","reason":"..."}]}
    """

    static func userMessage(for batch: [Highlight], context: String?) -> String {
        var user = ""
        if let context, !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            user += "About the source recording: \(context.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
        }
        user += "Candidates (\(batch.count)):\n" + candidatesJSON(batch)
        user += "\n\nReturn {\"rankings\":[...]} with one entry per candidate id."
        return user
    }

    struct PromptCandidate: Encodable {
        var id: Int
        var duration: Double
        var signals: [String: Double]
        var text: String
    }

    static func candidatesJSON(_ batch: [Highlight]) -> String {
        let items = batch.enumerated().map { i, h in
            PromptCandidate(id: i + 1, duration: (h.duration * 10).rounded() / 10,
                            signals: h.signals.mapValues { ($0 * 100).rounded() / 100 },
                            text: excerpt(h.text))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(items)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    static func excerpt(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > maxExcerpt else { return t }
        let cut = t.prefix(maxExcerpt)
        let word = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return String(word) + " …"
    }
}

/// One entry of the model's `{"rankings":[...]}` reply. `id` is the 1-based candidate position in the batch.
struct LLMRanking: Sendable, Equatable {
    var id: Int
    var score: Double
    var title: String?
    var reason: String?
}

extension LLMResponseParser {
    /// Rankings from a model reply, or nil if no usable JSON was found.
    static func rankings(from content: String) -> [LLMRanking]? {
        firstJSON(in: stripThinking(content), extract)
    }

    static func extract(_ value: Any) -> [LLMRanking]? {
        let items: [Any]
        if let dict = value as? [String: Any] {
            if let list = dict["rankings"] as? [Any] {
                items = list
            } else if dict["id"] != nil, dict["score"] != nil {
                items = [dict]
            } else if let list = dict.values.compactMap({ $0 as? [Any] }).first(where: { $0.first is [String: Any] }) {
                items = list
            } else {
                return nil
            }
        } else if let list = value as? [Any], list.first is [String: Any] {
            items = list
        } else {
            return nil
        }
        let parsed = items.compactMap { ($0 as? [String: Any]).flatMap(ranking) }
        return parsed.isEmpty && !items.isEmpty ? nil : parsed
    }

    static func ranking(_ d: [String: Any]) -> LLMRanking? {
        guard let id = int(d["id"]), let raw = double(d["score"]), raw.isFinite else { return nil }
        return LLMRanking(id: id, score: min(max(raw, 0), 10), title: d["title"] as? String,
                          reason: (d["reason"] as? String) ?? (d["why"] as? String))
    }
}
