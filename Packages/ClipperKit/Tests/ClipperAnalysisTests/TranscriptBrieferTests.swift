@testable import ClipperAnalysis
import ClipperCore
import Foundation
import Synchronization
import Testing

/// `count` sentences of `wordsPerSentence` words, 3 s apart, each ending in a period; sentence i starts at 3i seconds.
private func transcript(sentences count: Int, wordsPerSentence: Int = 5) -> Transcript {
    var words: [TranscriptWord] = []
    for s in 0..<count {
        for w in 0..<wordsPerSentence {
            let t = Double(s) * 3 + Double(w) * 0.4
            let text = w == wordsPerSentence - 1 ? "end\(s)." : "word\(s)x\(w)"
            words.append(TranscriptWord(text: text, start: t, end: t + 0.3))
        }
    }
    return Transcript(locale: "en-US", engine: "test", words: words)
}

private func json(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

private extension MockLLMServer.Request {
    var systemMessage: String {
        ((json["messages"] as? [[String: Any]]) ?? []).first { $0["role"] as? String == "system" }?["content"] as? String ?? ""
    }
    /// Sentence ids listed as "[id] text" lines.
    var sentenceIDs: [Int] { userMessage.matches(of: #/\[(\d+)\] /#).compactMap { Int($0.1) } }
    var isFinal: Bool { userMessage.contains("Candidate opening sentences") }
}

private func session() -> URLSession { URLSession(configuration: .ephemeral) }

@Suite struct TranscriptBrieferTests {
    @Test func oneRequestCleansAndClampsTheAnswer() async throws {
        let server = try await MockLLMServer { _ in
            (200, MockLLMServer.chat(json([
                "title": "\"🔥 Why this camera changed everything about how I film my videos forever\" 🚀",
                "hook": 2,
                "importance": [1.5, -0.2, 0.5],
                "chapters": [["sentence": 0, "title": "Intro"], ["sentence": 7, "title": "Out of range"],
                             ["sentence": 2, "title": "The test"]],
                "description": "  A review of a camera.  ",
                "hashtags": ["#Camera", "Video Gear", "camera", "a", "b", "c", "d", "e", "f", "g"],
            ])))
        }
        let briefer = TranscriptBriefer(endpoint: server.endpoint(), cache: nil, session: session())
        let progress = ProgressLog()
        let b = try await briefer.brief(transcript(sentences: 4), key: AssetKey("k"), context: "A camera review",
                                        progress: progress.callback)

        #expect(b.model == "test-model")
        let title = try #require(b.title)
        #expect(title.count <= 60 && !title.contains("\"") && !title.contains("🔥") && !title.contains("🚀"))
        #expect(title.hasPrefix("Why this camera"))
        #expect(b.hookSentence == 2)
        #expect(b.sentenceImportance == [1, 0, 0.5, 0])
        #expect(b.chapters == [.init(start: 0, title: "Intro"), .init(start: 6, title: "The test")])
        #expect(b.description == "A review of a camera.")
        #expect(b.hashtags == ["camera", "videogear", "a", "b", "c", "d", "e", "f"])
        #expect(progress.all.first == 0 && progress.all.last == 1)

        let reqs = server.chatRequests
        try #require(reqs.count == 1)
        #expect(reqs[0].responseFormatType == "json_schema")
        #expect(reqs[0].sentenceIDs == [0, 1, 2, 3])
        #expect(reqs[0].userMessage.contains("A camera review") && reqs[0].userMessage.contains("exactly 4 importance"))
        #expect(!reqs[0].userMessage.contains("end0. word1x0"))
    }

    @Test func longTranscriptsAreChunkedAtTheWordBudget() async throws {
        let server = try await MockLLMServer { req in
            if req.isFinal {
                return (200, MockLLMServer.chat(json(["title": "Final", "hook": 7, "description": "D", "hashtags": ["x"]])))
            }
            let ids = req.sentenceIDs
            return (200, MockLLMServer.chat(json([
                "summary": "Part starting at \(ids[0])",
                "importance": ids.map { Double($0) / 10 },
                "chapters": [["sentence": ids[0], "title": "From \(ids[0])"], ["sentence": 99, "title": "Elsewhere"]],
            ])))
        }
        // 10 sentences × 5 words, 12-word budget: chunks of two sentences.
        let briefer = TranscriptBriefer(endpoint: server.endpoint(), cache: nil, chunkWords: 12, session: session())
        let progress = ProgressLog()
        let b = try await briefer.brief(transcript(sentences: 10), key: AssetKey("k"), progress: progress.callback)

        let reqs = server.chatRequests
        #expect(reqs.count == 6)
        #expect(reqs.dropLast().map(\.sentenceIDs) == [[0, 1], [2, 3], [4, 5], [6, 7], [8, 9]])
        #expect(reqs.dropLast().allSatisfy { $0.systemMessage.contains("one part") })
        let final = try #require(reqs.last)
        #expect(final.isFinal && final.userMessage.contains("1. Part starting at 0") && final.userMessage.contains("5. Part starting at 8"))
        #expect(final.sentenceIDs == Array(0...9))   // budget allows 3 hooks per chunk; each chunk has 2
        #expect(b.sentenceImportance == (0..<10).map { Double($0) / 10 })
        #expect(b.chapters.map(\.start) == [0, 6, 12, 18, 24])
        #expect(b.title == "Final" && b.hookSentence == 7 && b.hashtags == ["x"])
        let expected: [Double] = [0] + (1...5).map { Double($0) / 6 } + [1]
        #expect(progress.all == expected)
    }

    @Test func fallsBackWhenJSONSchemaIsRejectedAndRemembersIt() async throws {
        let server = try await MockLLMServer { req in
            if req.responseFormatType != nil { return (400, #"{"error":"response_format not supported"}"#) }
            if req.isFinal { return (200, MockLLMServer.chat(#"Sure! {"title":"T","hook":0,"description":"","hashtags":[]}"#)) }
            return (200, MockLLMServer.chat(json(["summary": "s", "importance": req.sentenceIDs.map { _ in 0.5 }, "chapters": []])))
        }
        let briefer = TranscriptBriefer(endpoint: server.endpoint(), cache: nil, chunkWords: 5, session: session())
        let b = try await briefer.brief(transcript(sentences: 2), key: AssetKey("k"))
        #expect(server.chatRequests.map(\.responseFormatType) == ["json_schema", "json_object", nil, nil, nil])
        #expect(b.title == "T" && b.hookSentence == 0 && b.description == nil && b.sentenceImportance == [0.5, 0.5])
    }

    @Test func unparsableReplyIsAskedOnceMoreThenThrows() async throws {
        let server = try await MockLLMServer { _ in (200, MockLLMServer.chat("I can't do that.")) }
        let briefer = TranscriptBriefer(endpoint: server.endpoint(), cache: nil, session: session())
        await #expect(throws: LLMRankerError.self) {
            _ = try await briefer.brief(transcript(sentences: 2), key: AssetKey("k"))
        }
        #expect(server.chatRequests.count == 2)
    }

    @Test func cacheHitMakesNoRequest() async throws {
        let server = try await MockLLMServer { req in
            (200, MockLLMServer.chat(json(["title": "Cached", "hook": 0, "importance": req.sentenceIDs.map { _ in 1 },
                                           "chapters": [], "description": "d", "hashtags": []])))
        }
        let dir = FileManager.default.temporaryDirectory.appending(path: "brief-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let briefer = TranscriptBriefer(endpoint: server.endpoint(), cache: DirectoryAnalysisCache(directory: dir),
                                        session: session())
        let t = transcript(sentences: 3)
        let first = try await briefer.brief(t, key: AssetKey("asset"))
        let second = try await briefer.brief(t, key: AssetKey("asset"))
        #expect(first == second && second.title == "Cached")
        #expect(server.chatRequests.count == 1)
        #expect(briefer.analyzerID(t, context: nil).hasPrefix("brief.test-model."))

        _ = try await briefer.brief(t, key: AssetKey("asset"), context: "Other context")
        #expect(server.chatRequests.count == 2)
    }

    @Test func cacheWorksForModelIdsWithTagsAndOrgs() async throws {
        /// Refuses the file-name characters the library refuses.
        final class StrictCache: AnalysisCache, @unchecked Sendable {
            let inner = Mutex<[String: Data]>([:])
            func load(key: AssetKey, analyzer: String, version: Int) async -> Data? { inner.withLock { $0[analyzer] } }
            func store(_ data: Data, key: AssetKey, analyzer: String, version: Int) async throws {
                guard !analyzer.contains(":"), !analyzer.contains("/") else { throw CancellationError() }
                inner.withLock { $0[analyzer] = data }
            }
        }
        let server = try await MockLLMServer { req in
            (200, MockLLMServer.chat(json(["title": "T", "hook": 0, "importance": req.sentenceIDs.map { _ in 1 },
                                           "chapters": [], "description": "d", "hashtags": []])))
        }
        let briefer = TranscriptBriefer(endpoint: server.endpoint(model: "org/qwen3.5:9b"), cache: StrictCache(),
                                        session: session())
        let t = transcript(sentences: 2)
        _ = try await briefer.brief(t, key: AssetKey("asset"))
        _ = try await briefer.brief(t, key: AssetKey("asset"))
        #expect(server.chatRequests.count == 1)
        #expect(briefer.analyzerID(t, context: nil).hasPrefix("brief.org_qwen3.5_9b."))
    }

    @Test func emptyTranscriptAndNonLocalEndpoints() async throws {
        let unreachable = LLMEndpoint(baseURL: URL(string: "http://127.0.0.1:1/v1")!, model: "m")
        let empty = try await TranscriptBriefer(endpoint: unreachable, cache: nil)
            .brief(Transcript(locale: "en-US", engine: "x", words: []), key: AssetKey("k"))
        #expect(empty == TranscriptBrief(model: "m"))

        let cloud = LLMEndpoint(baseURL: URL(string: "http://localhost:11434/v1")!, model: "glm-5:cloud")
        await #expect(throws: LLMRankerError.self) {
            _ = try await TranscriptBriefer(endpoint: cloud, cache: nil).brief(transcript(sentences: 1), key: AssetKey("k"))
        }
    }
}
