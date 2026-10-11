@testable import ClipperAnalysis
import ClipperCore
import Foundation
import Network
import Synchronization
import Testing

// MARK: - Mock OpenAI-compatible server

/// A tiny in-process HTTP/1.1 server on 127.0.0.1 (random port) that answers each request through `handler`.
final class MockLLMServer: @unchecked Sendable {
    struct Request: Sendable {
        var method: String
        var path: String
        var body: Data

        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:] }
        var responseFormatType: String? { (json["response_format"] as? [String: Any])?["type"] as? String }
        var userMessage: String {
            ((json["messages"] as? [[String: Any]]) ?? []).last { $0["role"] as? String == "user" }?["content"] as? String ?? ""
        }
        /// Candidate ids listed in the user message.
        var candidateIDs: [Int] {
            let s = userMessage
            return s.matches(of: /"id":(\d+)/).compactMap { Int($0.1) }
        }
    }

    typealias Handler = @Sendable (Request) -> (status: Int, body: String)

    private let listener: NWListener
    private let queue = DispatchQueue(label: "MockLLMServer")
    private let handler: Handler
    private let log = Mutex<[Request]>([])
    private(set) var port: UInt16 = 0

    var requests: [Request] { log.withLock { $0 } }
    var chatRequests: [Request] { requests.filter { $0.path.hasSuffix("/chat/completions") } }
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)/v1")! }
    func endpoint(model: String = "test-model") -> LLMEndpoint { LLMEndpoint(baseURL: baseURL, model: model, timeout: 10) }

    init(handler: @escaping Handler) async throws {
        self.handler = handler
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        listener.newConnectionHandler = { [unowned self] conn in
            conn.start(queue: self.queue)
            self.receive(conn, buffer: Data())
        }
        let resumed = Mutex(false)
        port = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, any Error>) in
            listener.stateUpdateHandler = { [listener] state in
                let value: Result<UInt16, any Error>?
                switch state {
                case .ready: value = .success(listener.port?.rawValue ?? 0)
                case let .failed(error): value = .failure(error)
                default: value = nil
                }
                guard let value, resumed.withLock({ let first = !$0; $0 = true; return first }) else { return }
                cont.resume(with: value)
            }
            listener.start(queue: queue)
        }
    }

    deinit { listener.cancel() }

    /// Convenience: answer chat completions with `content` as the assistant message (status 200).
    static func chat(_ content: String) -> String {
        let body: [String: Any] = ["id": "x", "object": "chat.completion",
                                   "choices": [["index": 0, "message": ["role": "assistant", "content": content]]]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: body), as: UTF8.self)
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [self] data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                log.withLock { $0.append(request) }
                let (status, body) = handler(request)
                let payload = Data(body.utf8)
                var head = "HTTP/1.1 \(status) \(status < 300 ? "OK" : "Error")\r\n"
                head += "Content-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(head.utf8) + payload, contentContext: .finalMessage, isComplete: true,
                          completion: .contentProcessed { _ in conn.cancel() })
            } else if isComplete || error != nil {
                conn.cancel()
            } else {
                receive(conn, buffer: buffer)
            }
        }
    }

    private static func parse(_ buffer: Data) -> Request? {
        guard let split = buffer.firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[..<split.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        let length = lines.dropFirst().compactMap { line -> Int? in
            let kv = line.split(separator: ":", maxSplits: 1)
            guard kv.count == 2, kv[0].lowercased() == "content-length" else { return nil }
            return Int(kv[1].trimmingCharacters(in: .whitespaces))
        }.first ?? 0
        let body = buffer[split.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(parts[0]), path: String(parts[1]), body: Data(body.prefix(length)))
    }
}

/// Collects progress callbacks.
final class ProgressLog: Sendable {
    private let values = Mutex<[Double]>([])
    var all: [Double] { values.withLock { $0 } }
    var callback: @Sendable (Double) -> Void { { [self] v in values.withLock { $0.append(v) } } }
}

private func candidate(_ i: Int, score: Double, reason: String = "loud", text: String? = nil) -> Highlight {
    Highlight(start: Double(i) * 60, end: Double(i) * 60 + 30, score: score, reason: reason,
              text: text ?? "Candidate number \(i) says something.", signals: ["loudness": 0.5, "laughter": 0.123456])
}

private func rankingsJSON(_ items: [(id: Int, score: Double, title: String, reason: String)]) -> String {
    let list = items.map { ["id": $0.id, "score": $0.score, "title": $0.title, "reason": $0.reason] as [String: Any] }
    return String(decoding: try! JSONSerialization.data(withJSONObject: ["rankings": list]), as: UTF8.self)
}

private func session() -> URLSession { URLSession(configuration: .ephemeral) }

// MARK: - Tests

@Suite("LocalLLMRanker")
struct LLMRankerTests {
    @Test func happyPathBlendsTitlesAndSorts() async throws {
        let server = try await MockLLMServer { _ in
            (200, MockLLMServer.chat(rankingsJSON([
                (1, 10, "You won't believe this", "Instant hook"),
                (2, 0, "Boring", "Dead air"),
                (3, 8, "The twist", "Great payoff\nsecond line ignored"),
            ])))
        }
        let ranker = LocalLLMRanker(endpoint: server.endpoint(), session: session())
        let progress = ProgressLog()
        let input = [candidate(1, score: 0.5), candidate(2, score: 0.9), candidate(3, score: 0.2, reason: "")]
        let out = try await ranker.rank(input, context: "A cooking stream", progress: progress.callback)

        #expect(out.map(\.start) == [60, 180, 120])  // c1 0.8, c3 0.56, c2 0.36
        #expect(abs(out[0].score - 0.8) < 1e-9)
        #expect(abs(out[1].score - 0.56) < 1e-9)
        #expect(abs(out[2].score - 0.36) < 1e-9)
        #expect(out[0].title == "You won't believe this")
        #expect(out[0].reason == "Instant hook — loud")
        #expect(out[1].reason == "Great payoff")
        #expect(out[0].signals["llm"] == 1.0)
        #expect(Set(out.map(\.end)) == Set(input.map(\.end)))
        #expect(progress.all.first == 0 && progress.all.last == 1)

        let reqs = server.chatRequests
        try #require(reqs.count == 1)
        let r = reqs[0]
        #expect(r.method == "POST" && r.path == "/v1/chat/completions")
        #expect(r.json["temperature"] as? Double == 0.2)
        #expect(r.json["model"] as? String == "test-model")
        #expect(r.responseFormatType == "json_schema")
        #expect(r.json["reasoning_effort"] as? String == "none")
        #expect(r.candidateIDs == [1, 2, 3])
        #expect(r.userMessage.contains("A cooking stream"))
        #expect(r.userMessage.contains("\"laughter\":0.12"))
        let system = ((r.json["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
        #expect(system.contains("first 3 seconds") && system.contains("mid-sentence"))
    }

    @Test func parsesFencedAndThinkWrappedOutput() async throws {
        let longTitle = "\"This is a very long title that definitely goes past the sixty character limit\""
        let content = """
        <think>
        Okay, candidate 1 looks {interesting}. Let me output {"rankings": []}... no wait.
        </think>
        Here you go:
        ```json
        {"rankings": [{"id": "2", "score": "7", "title": \(longTitle.debugDescription), "reason": "Solid"},
                      {"id": 1, "score": 3.5, "title": "Meh", "reason": "Slow start"}]}
        ```
        """
        let server = try await MockLLMServer { _ in (200, MockLLMServer.chat(content)) }
        let ranker = LocalLLMRanker(endpoint: server.endpoint(), session: session())
        let out = try await ranker.rank([candidate(1, score: 0.5), candidate(2, score: 0.5)])
        #expect(out.map(\.start) == [120, 60])
        #expect(abs(out[0].score - (0.6 * 0.7 + 0.2)) < 1e-9)
        let title = try #require(out[0].title)
        #expect(title.count <= 60 && title.hasSuffix("…") && !title.hasPrefix("\""))
        #expect(out[1].title == "Meh")
    }

    @Test func fallsBackWhenJSONSchemaIsRejected() async throws {
        let server = try await MockLLMServer { req in
            if req.responseFormatType != nil {
                return (400, #"{"error":{"message":"response_format type not supported"}}"#)
            }
            let ids = req.candidateIDs
            return (200, MockLLMServer.chat(rankingsJSON(ids.map { ($0, 5, "T\($0)", "ok") })))
        }
        let ranker = LocalLLMRanker(endpoint: server.endpoint(), batchSize: 2, session: session())
        let out = try await ranker.rank((1...3).map { candidate($0, score: 0.5) })
        #expect(out.allSatisfy { abs($0.score - 0.5) < 1e-9 && $0.title != nil })
        // json_schema → json_object → none, then the second batch goes straight to the format that worked.
        #expect(server.chatRequests.map(\.responseFormatType) == ["json_schema", "json_object", nil, nil])
        #expect(server.chatRequests.last?.json["reasoning_effort"] == nil)
    }

    @Test func omittedAndUnknownIDsKeepHeuristicScore() async throws {
        let server = try await MockLLMServer { _ in
            (200, MockLLMServer.chat(rankingsJSON([(1, 15, "Clamped", "Too good"), (99, 10, "Ghost", "Unknown id")])))
        }
        let ranker = LocalLLMRanker(endpoint: server.endpoint(), session: session())
        let out = try await ranker.rank([candidate(1, score: 0.1), candidate(2, score: 0.95, reason: "laughter")])
        #expect(out.count == 2)
        let c1 = try #require(out.first { $0.start == 60 })
        let c2 = try #require(out.first { $0.start == 120 })
        #expect(abs(c1.score - (0.6 + 0.04)) < 1e-9)  // 15 clamped to 10
        #expect(c2.score == 0.95 && c2.title == nil && c2.reason == "laughter" && c2.signals["llm"] == nil)
        #expect(out.map(\.start) == [120, 60])
    }

    @Test func unreachableServer() async throws {
        let endpoint = LLMEndpoint(baseURL: URL(string: "http://127.0.0.1:1/v1")!, model: "qwen3:14b", timeout: 5)
        let ranker = LocalLLMRanker(endpoint: endpoint, session: session())
        #expect(await ranker.isAvailable() == false)
        let error = await #expect(throws: LLMRankerError.self) {
            _ = try await ranker.rank([candidate(1, score: 0.5)])
        }
        guard case .unreachable = error else { Issue.record("expected .unreachable, got \(String(describing: error))"); return }
        #expect(LLMRankerError.unreachable(.ollama, reason: "refused").description.contains("ollama pull qwen3:14b"))
        #expect(LLMRankerError.unreachable(.lmStudio, reason: "refused").description.contains("LM Studio"))
        #expect(LLMRankerError.unreachable(.mlxServer, reason: "refused").description.contains("mlx_lm.server"))
    }

    @Test func batchesSequentially() async throws {
        let server = try await MockLLMServer { req in
            (200, MockLLMServer.chat(rankingsJSON(req.candidateIDs.map { ($0, Double($0 % 11), "t", "r") })))
        }
        let ranker = LocalLLMRanker(endpoint: server.endpoint(), batchSize: 20, session: session())
        let progress = ProgressLog()
        let input = (1...45).map { candidate($0, score: 0.5) }
        let out = try await ranker.rank(input, progress: progress.callback)
        #expect(server.chatRequests.count == 3)
        #expect(server.chatRequests.map { $0.candidateIDs.count } == [20, 20, 5])
        #expect(out.count == 45 && out.allSatisfy { $0.signals["llm"] != nil })
        #expect(zip(out, out.dropFirst()).allSatisfy { $0.score >= $1.score })
        #expect(progress.all == [0, 20.0 / 45, 40.0 / 45, 1])
        // Batch 3's id 5 is input[44].
        #expect(out.first { $0.start == input[44].start }?.signals["llm"] == 0.5)
    }

    @Test func modelsAndAvailability() async throws {
        let server = try await MockLLMServer { req in
            req.path.hasSuffix("/models")
                ? (200, #"{"object":"list","data":[{"id":"qwen3:14b"},{"id":"llama3.2:latest"}]}"#)
                : (404, "")
        }
        let s = session()
        #expect(try await LocalLLMRanker(endpoint: server.endpoint(model: "qwen3:14b"), session: s).models()
            == ["qwen3:14b", "llama3.2:latest"])
        #expect(await LocalLLMRanker(endpoint: server.endpoint(model: "qwen3:14b"), session: s).isAvailable())
        #expect(await LocalLLMRanker(endpoint: server.endpoint(model: "llama3.2"), session: s).isAvailable())
        #expect(await LocalLLMRanker(endpoint: server.endpoint(model: "missing"), session: s).isAvailable() == false)

        let empty = try await MockLLMServer { _ in (200, #"{"data":[]}"#) }
        #expect(await LocalLLMRanker(endpoint: empty.endpoint(model: "anything"), session: s).isAvailable())
    }

    @Test func errorsAreTyped() async throws {
        let s = session()
        let garbage = try await MockLLMServer { _ in (200, MockLLMServer.chat("Sorry, I can't help with that.")) }
        let e1 = await #expect(throws: LLMRankerError.self) {
            _ = try await LocalLLMRanker(endpoint: garbage.endpoint(), session: s).rank([candidate(1, score: 0.5)])
        }
        guard case .unparsable(let raw) = e1 else { Issue.record("expected .unparsable"); return }
        #expect(raw.contains("Sorry"))
        #expect(garbage.chatRequests.count == 2)  // one re-ask

        let missing = try await MockLLMServer { _ in (404, #"{"error":"model 'x' not found"}"#) }
        let e2 = await #expect(throws: LLMRankerError.self) {
            _ = try await LocalLLMRanker(endpoint: missing.endpoint(), session: s).rank([candidate(1, score: 0.5)])
        }
        guard case .badStatus(404, _) = e2 else { Issue.record("expected .badStatus(404)"); return }
        #expect(missing.chatRequests.count == 1)  // 404 is not a format rejection
        #expect(e2?.description.contains("ollama pull") == true)
    }

    @Test func emptyInputMakesNoRequest() async throws {
        let endpoint = LLMEndpoint(baseURL: URL(string: "http://127.0.0.1:1/v1")!, model: "m")
        #expect(try await LocalLLMRanker(endpoint: endpoint).rank([]).isEmpty)
    }

    @Test func parserEdgeCases() {
        #expect(LLMResponseParser.rankings(from: #"[{"id":1,"score":9}]"#) == [LLMRanking(id: 1, score: 9)])
        #expect(LLMResponseParser.rankings(from: ##"{"results":[{"id":"#2","score":"8/10"}]}"##)
            == [LLMRanking(id: 2, score: 8)])
        // Template pre-opened <think>, so only the closing tag appears.
        #expect(LLMResponseParser.rankings(from: "hmm {x}</think>{\"rankings\":[]}") == [])
        #expect(LLMResponseParser.rankings(from: "<think>never finished {\"rankings\":[{\"id\":1,\"score\":2}]}") == nil)
        #expect(LLMResponseParser.rankings(from: #"{"rankings":[{"title":"no id"}]}"#) == nil)
        #expect(LLMResponseParser.rankings(from: #"{"note":"a } in a string","rankings":[{"id":3,"score":-4}]}"#)
            == [LLMRanking(id: 3, score: 0)])
        #expect(LocalLLMRanker.cleanTitle(" ... ").isEmpty && LocalLLMRanker.cleanTitle("“Hook!”") == "Hook!")
        #expect(LocalLLMRanker.excerpt(String(repeating: "word ", count: 600)).count <= 1202)
        let decoded = try? JSONDecoder().decode(LLMEndpoint.self, from: Data(#"{"baseURL":"http://localhost:1234/v1","model":"m"}"#.utf8))
        #expect(decoded?.timeout == 120)
    }

    // MARK: Live

    /// A real local server, if one is running: the default endpoint's model if it is installed, otherwise the first
    /// local (non-cloud, non-embedding) model it lists, or `CLIPPER_LLM_MODEL`. Set `CLIPPER_SKIP_LIVE_LLM=1` to skip.
    static func liveEndpoint() async -> LLMEndpoint? {
        let env = ProcessInfo.processInfo.environment
        guard env["CLIPPER_SKIP_LIVE_LLM"] == nil else { return nil }
        for base in LLMEndpoint.defaults {
            let probe = LocalLLMRanker(endpoint: LLMEndpoint(baseURL: base.baseURL, model: base.model, timeout: 2))
            guard let ids = try? await probe.models() else { continue }
            let model = env["CLIPPER_LLM_MODEL"]
                ?? (ids.contains(base.model) ? base.model : nil)
                ?? ids.first { !$0.contains("cloud") && !$0.contains("embed") }
            if let model { return LLMEndpoint(baseURL: base.baseURL, model: model, timeout: 300) }
        }
        return nil
    }

    @Test(.enabled("no local OpenAI-compatible LLM server running") { await liveEndpoint() != nil },
          .timeLimit(.minutes(5)))
    func liveSmoke() async throws {
        let endpoint = try #require(await Self.liveEndpoint())
        let ranker = LocalLLMRanker(endpoint: endpoint)
        let input = [
            Highlight(start: 0, end: 20, score: 0.4, reason: "heuristic",
                      text: "and then, um, yeah so like I said before, that thing, you know, the one from earlier"),
            Highlight(start: 100, end: 130, score: 0.4, reason: "heuristic",
                      text: "I quit my job, sold everything, and moved to a boat. Six months later the boat sank, and it was the best thing that ever happened to me."),
            Highlight(start: 300, end: 325, score: 0.4, reason: "heuristic",
                      text: "Okay let me just check the audio levels real quick, can everyone hear me, one two one two."),
        ]
        let started = Date()
        let out = try await ranker.rank(input, context: "Podcast episode")
        print("live LLM (\(endpoint.model) @ \(endpoint.baseURL.absoluteString)) took \(Int(Date().timeIntervalSince(started))) s:")
        for h in out { print(String(format: "  %.2f  %@  | %@", h.score, h.title ?? "-", h.reason)) }
        #expect(out.count == 3)
        #expect(Set(out.map(\.start)) == [0, 100, 300])
        #expect(out.allSatisfy { (0...1).contains($0.score) && ($0.title?.count ?? 0) <= 60 })
        #expect(out.contains { $0.signals["llm"] != nil })
    }
}
