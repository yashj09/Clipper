import ClipperCore
import Foundation

// Clipper's only way to reach a language model: a user-run, OpenAI-compatible server on this Mac (Ollama, LM Studio,
// mlx_lm.server). Clipper never embeds a model and never talks to the cloud: the endpoint must be loopback.
// Without a server, every feature built on this falls back to working without it.

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
    /// The model's reply did not contain the JSON that was asked for.
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
            return "The model's reply wasn't the JSON Clipper asked for: \"\(excerpt)\". "
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

/// Chat completions against a local OpenAI-compatible server. Remembers which `response_format` the server accepted, so
/// after a rejection the following calls on this client go straight to the format that worked.
public actor LocalLLM {
    public let endpoint: LLMEndpoint
    let session: URLSession
    private var format = ResponseFormat.jsonSchema

    public init(endpoint: LLMEndpoint, session: URLSession = .shared) {
        self.endpoint = endpoint; self.session = session
    }

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

    /// One chat completion. `schema` is an OpenAI `json_schema` object (`name`, `strict`, `schema`); servers that reject
    /// it are retried with `json_object`, then with no format. `parse` sees each text the reply carries (content first,
    /// then reasoning fields) with `<think>` blocks removed, and the first value it returns wins. A reply nothing
    /// parses is asked once more, then throws `.unparsable`.
    func complete<T: Sendable>(system: String, user: String, schema: sending [String: Any],
                               parse: @Sendable (String) -> T?) async throws -> T {
        if let why = endpoint.nonLocalReason { throw LLMRankerError.notLocal(why) }
        let messages = [["role": "system", "content": system], ["role": "user", "content": user]]
        var reparsed = false
        while true {
            try Task.checkCancellation()
            let request = try makeChatRequest(messages: messages, schema: schema)
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
                if let value = parse(LLMResponseParser.stripThinking(content)) { return value }
            }
            // Sampling at temperature 0.2 occasionally derails small models; give each request one more try.
            if !reparsed { reparsed = true; continue }
            throw LLMRankerError.unparsable(contents.first ?? String(decoding: data, as: UTF8.self))
        }
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            // Never follow redirects: a 3xx from the local server must not resend the transcript elsewhere.
            let (data, response) = try await session.data(for: request, delegate: RefuseRedirects())
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
            let reason = error.code == .timedOut
                ? "timed out after \(Int(request.timeoutInterval)) s; raise LLMEndpoint.timeout for slow models"
                : error.localizedDescription
            throw LLMRankerError.unreachable(endpoint, reason: reason)
        }
    }

    enum ResponseFormat: Equatable {
        case jsonSchema, jsonObject, none
        var fallback: ResponseFormat? {
            switch self { case .jsonSchema: .jsonObject; case .jsonObject: ResponseFormat.none; case .none: nil }
        }
    }

    private func makeChatRequest(messages: [[String: String]], schema: [String: Any]) throws -> URLRequest {
        var body: [String: Any] = [
            "model": endpoint.model,
            "messages": messages,
            "temperature": 0.2,
            "stream": false,
        ]
        switch format {
        case .jsonSchema: body["response_format"] = ["type": "json_schema", "json_schema": schema]
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

/// Stops URLSession from following redirects; the 3xx response is returned to the caller instead.
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}
