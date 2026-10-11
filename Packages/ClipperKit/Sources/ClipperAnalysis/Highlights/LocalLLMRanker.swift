import ClipperCore
import Foundation

// Optional highlight re-ranking through a user-run, OpenAI-compatible LLM server on this machine
// (Ollama, LM Studio, mlx_lm.server). Clipper never embeds a model and never talks to the cloud: the endpoint is
// expected to be localhost. Without a server the heuristic scores are used as they are.

/// Where the local OpenAI-compatible server lives and which model to ask.
public struct LLMEndpoint: Sendable, Codable, Equatable {
    /// API root including the version path, e.g. `http://localhost:11434/v1`.
    public var baseURL: URL
    /// Model id as the server knows it, e.g. `qwen3:14b`.
    public var model: String
    /// Seconds allowed for one chat completion (local models can be slow on long batches).
    public var timeout: Double = 120
    /// Let reasoning models (Qwen3, gpt-oss, R1 distills) think before answering. Off by default: thinking costs
    /// minutes per batch on a laptop for little ranking gain. When off, the request carries the common "don't think"
    /// hints (`reasoning_effort: none`, `chat_template_kwargs.enable_thinking: false`); servers ignore what they don't know.
    public var reasoning: Bool = false

    public init(baseURL: URL, model: String, timeout: Double = 120, reasoning: Bool = false) {
        self.baseURL = baseURL; self.model = model; self.timeout = timeout; self.reasoning = reasoning
    }

    private enum CodingKeys: String, CodingKey { case baseURL, model, timeout, reasoning }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try c.decode(URL.self, forKey: .baseURL)
        model = try c.decode(String.self, forKey: .model)
        timeout = try c.decodeIfPresent(Double.self, forKey: .timeout) ?? 120
        reasoning = try c.decodeIfPresent(Bool.self, forKey: .reasoning) ?? false
    }

    /// `ollama serve` (default port 11434).
    public static let ollama = LLMEndpoint(baseURL: URL(string: "http://localhost:11434/v1")!, model: "qwen3:14b")
    /// LM Studio's local server (default port 1234).
    public static let lmStudio = LLMEndpoint(baseURL: URL(string: "http://localhost:1234/v1")!, model: "qwen/qwen3-14b")
    /// `mlx_lm.server` (default port 8080).
    public static let mlxServer = LLMEndpoint(baseURL: URL(string: "http://localhost:8080/v1")!,
                                              model: "mlx-community/Qwen3-14B-4bit")

    /// The well-known local servers, in the order they are usually tried.
    public static let defaults: [LLMEndpoint] = [.ollama, .lmStudio, .mlxServer]
}

public enum LLMRankerError: Error, Sendable, Equatable, CustomStringConvertible {
    /// No server answered (connection refused, timed out, ...).
    case unreachable(LLMEndpoint, reason: String)
    /// The server answered with a non-2xx status.
    case badStatus(Int, body: String)
    /// The model's reply did not contain usable ranking JSON.
    case unparsable(String)
    /// The endpoint or model would send transcripts off this Mac (non-loopback host, or a cloud-backed model).
    case notLocal(String)

    public var description: String {
        switch self {
        case let .unreachable(endpoint, reason):
            return "No local LLM server at \(endpoint.baseURL.absoluteString) (\(reason)). " + Self.startHint(endpoint)
        case let .badStatus(code, body):
            var s = "The local LLM server returned HTTP \(code)"
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { s += ": \(trimmed.prefix(300))" }
            s += "."
            if code == 404 || body.localizedCaseInsensitiveContains("not found") {
                s += " Make sure the model is downloaded and loaded (e.g. `ollama pull qwen3:14b`, or load it in LM Studio)"
                    + " and that the base URL ends in /v1."
            }
            return s
        case let .notLocal(why):
            return "Clipper only uses models running on this Mac: \(why). Pick a local model (e.g. `ollama pull qwen3:14b`)."
        case let .unparsable(raw):
            let excerpt = raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)
            return "The model's reply wasn't valid ranking JSON: \"\(excerpt)\". "
                + "Try a larger instruction-tuned model (e.g. qwen3:14b) or a server that supports structured output."
        }
    }

    static func startHint(_ endpoint: LLMEndpoint) -> String {
        switch endpoint.baseURL.port {
        case 11434: "Start Ollama: `ollama serve` and `ollama pull \(endpoint.model)`."
        case 1234: "Open LM Studio, load \(endpoint.model) and start the server (Developer → Start Server, or `lms server start`)."
        case 8080: "Start it: `mlx_lm.server --model \(endpoint.model) --port 8080`."
        default: "Check that an OpenAI-compatible server is running there."
        }
    }
}

/// Re-scores highlight candidates for short-form potential with a local LLM.
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

    // MARK: Discovery

    /// True if the server answers GET {base}/models (and lists the model, if it lists any). Fast (≤ 2 s timeout).
    public func isAvailable() async -> Bool {
        guard endpoint.nonLocalReason == nil else { return false }
        guard let ids = try? await fetchModels(timeout: 2) else { return false }
        return ids.isEmpty || Self.contains(ids, model: endpoint.model)
    }

    /// Lists model ids from GET {base}/models.
    public func models() async throws -> [String] {
        try await fetchModels(timeout: min(endpoint.timeout, 10))
    }

    /// Ollama lists `name:tag`; treat a bare `name` as `name:latest`.
    static func contains(_ ids: [String], model: String) -> Bool {
        ids.contains(model) || (!model.contains(":") && ids.contains(model + ":latest"))
    }

    private func fetchModels(timeout: Double) async throws -> [String] {
        var request = URLRequest(url: endpoint.baseURL.appending(path: "models"))
        request.timeoutInterval = timeout
        let (data, code) = try await send(request)
        guard (200..<300).contains(code) else {
            throw LLMRankerError.badStatus(code, body: String(decoding: data, as: UTF8.self))
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMRankerError.unparsable(String(decoding: data, as: UTF8.self))
        }
        // OpenAI shape is {"data":[{"id":...}]}; tolerate Ollama's native {"models":[{"name":...}]} too.
        let list = (root["data"] as? [[String: Any]]) ?? (root["models"] as? [[String: Any]]) ?? []
        return list.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) ?? ($0["model"] as? String) }
    }

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
        var result = candidates
        var format = ResponseFormat.jsonSchema
        var start = 0
        while start < candidates.count {
            try Task.checkCancellation()
            let end = min(start + batchSize, candidates.count)
            let batch = Array(candidates[start..<end])
            let rankings = try await rankBatch(batch, context: context, format: &format)
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
    /// Returns rankings keyed by 0-based batch index. Downgrades `format` if the server rejects it (kept for later batches).
    private func rankBatch(_ batch: [Highlight], context: String?,
                           format: inout ResponseFormat) async throws -> [Int: LLMRanking] {
        let messages = Self.messages(for: batch, context: context)
        var reparsed = false
        while true {
            try Task.checkCancellation()
            let request = try makeChatRequest(messages: messages, format: format)
            let (data, code) = try await send(request)
            if (400..<500).contains(code), ![401, 403, 404, 408, 429].contains(code), let next = format.fallback {
                format = next
                continue
            }
            guard (200..<300).contains(code) else {
                throw LLMRankerError.badStatus(code, body: String(decoding: data, as: UTF8.self))
            }
            let contents = LLMResponseParser.messageContents(data)
            for content in contents {
                if let rankings = LLMResponseParser.rankings(from: content) {
                    var byIndex: [Int: LLMRanking] = [:]
                    for r in rankings where (1...batch.count).contains(r.id) && byIndex[r.id - 1] == nil {
                        byIndex[r.id - 1] = r
                    }
                    return byIndex
                }
            }
            // Sampling at temperature 0.2 occasionally derails small models; give each batch one more try.
            if !reparsed { reparsed = true; continue }
            throw LLMRankerError.unparsable(contents.first ?? String(decoding: data, as: UTF8.self))
        }
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
            let reason = error.code == .timedOut
                ? "timed out after \(Int(request.timeoutInterval)) s; raise LLMEndpoint.timeout for slow models"
                : error.localizedDescription
            throw LLMRankerError.unreachable(endpoint, reason: reason)
        }
    }

    // MARK: Request building

    enum ResponseFormat: Equatable {
        case jsonSchema, jsonObject, none
        var fallback: ResponseFormat? {
            switch self { case .jsonSchema: .jsonObject; case .jsonObject: ResponseFormat.none; case .none: nil }
        }
    }

    private func makeChatRequest(messages: [[String: String]], format: ResponseFormat) throws -> URLRequest {
        var body: [String: Any] = [
            "model": endpoint.model,
            "messages": messages,
            "temperature": 0.2,
            "stream": false,
        ]
        switch format {
        case .jsonSchema: body["response_format"] = ["type": "json_schema", "json_schema": Self.schema]
        case .jsonObject: body["response_format"] = ["type": "json_object"]
        case .none: break  // last resort: the plainest request possible, no extra hints either
        }
        if !endpoint.reasoning, format != .none {
            body["reasoning_effort"] = "none"
            body["chat_template_kwargs"] = ["enable_thinking": false]
        }
        var request = URLRequest(url: endpoint.baseURL.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = endpoint.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

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

    static func messages(for batch: [Highlight], context: String?) -> [[String: String]] {
        var user = ""
        if let context, !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            user += "About the source recording: \(context.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
        }
        user += "Candidates (\(batch.count)):\n" + candidatesJSON(batch)
        user += "\n\nReturn {\"rankings\":[...]} with one entry per candidate id."
        return [["role": "system", "content": systemPrompt], ["role": "user", "content": user]]
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


extension LLMEndpoint {
    /// Ollama names cloud-backed models with a `cloud` tag (e.g. `glm-5:cloud`, `gpt-oss:120b-cloud`).
    public static func isCloudModel(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.hasSuffix(":cloud") || n.hasSuffix("-cloud") || n.contains(":cloud-")
    }

    /// Why this endpoint isn't local-only, or nil when it is (loopback host and not a cloud-backed model).
    public var nonLocalReason: String? {
        let host = (baseURL.host ?? "").lowercased()
        if !["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) { return "\(host.isEmpty ? baseURL.absoluteString : host) is not this Mac" }
        if Self.isCloudModel(model) { return "“\(model)” is a cloud-backed model" }
        return nil
    }
}
