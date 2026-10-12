@testable import ClipperPublish
import CryptoKit
import Foundation
import Testing

/// Mock of TikTok's inbox upload: init, chunk PUTs to `upload_url`, and status polling.
final class MockTikTok: Sendable {
    struct State: Sendable {
        var initBody: [String: Any] { jsonObject(initBodyData) }
        var initBodyData = Data()
        var initHeaders: [String: String] = [:]
        var chunks: [(range: String, length: Int, contentType: String, authorization: String?)] = []
        var receivedBytes: Int64 = 0
        var hash = SHA256()
        var putAttempts = 0
        var served500 = 0
        var statusPolls = 0
        var statusBodies: [[String: Any]] { statusBodyData.map(jsonObject) }
        var statusBodyData: [Data] = []
    }

    let state: Box<State>
    let mock: MockServer

    init(fail500OnAttempt: Int? = nil, initError: String? = nil, statuses: [String] = ["PROCESSING_UPLOAD", "SEND_TO_USER_INBOX"],
         failReason: String? = nil) async throws {
        let state = Box(State())
        self.state = state
        mock = try await MockServer { request in
            let ok: [String: Any] = ["code": "ok", "message": "", "log_id": "log-1"]
            switch (request.method, request.path) {
            case ("POST", "/v2/post/publish/inbox/video/init/"):
                guard request.header("authorization") == "Bearer test-access" else {
                    return .json(["error": ["code": "access_token_invalid", "message": "", "log_id": "x"]], status: 401)
                }
                state.update { $0.initBodyData = request.body; $0.initHeaders = request.headers }
                if let initError {
                    return .json(["data": [:], "error": ["code": initError, "message": "Too many pending shares", "log_id": "log-2"]],
                                 status: 403)
                }
                let host = request.header("host") ?? "127.0.0.1"
                return .json(["data": ["publish_id": "v_inbox_file~v2.123",
                                       "upload_url": "http://\(host)/video/?upload_id=67890&upload_token=Xza123"],
                              "error": ok])

            case ("PUT", "/video/"):
                guard request.queryValue("upload_id") == "67890", request.queryValue("upload_token") == "Xza123",
                      let range = parseContentRange(request.header("content-range")) else { return HTTPServerResponse(status: 400) }
                return state.update { s -> HTTPServerResponse in
                    s.putAttempts += 1
                    if s.putAttempts == fail500OnAttempt { s.served500 += 1; return HTTPServerResponse(status: 500) }
                    guard range.start == s.receivedBytes, Int64(request.body.count) == range.end - range.start + 1,
                          Int(request.header("content-length") ?? "") == request.body.count else {
                        return HTTPServerResponse(status: 416)
                    }
                    s.chunks.append((request.header("content-range")!, request.body.count, request.header("content-type") ?? "",
                                     request.header("authorization")))
                    s.receivedBytes += Int64(request.body.count)
                    s.hash.update(data: request.body)
                    return HTTPServerResponse(status: s.receivedBytes == range.total ? 201 : 206)
                }

            case ("POST", "/v2/post/publish/status/fetch/"):
                let poll = state.update { s -> Int in s.statusPolls += 1; s.statusBodyData.append(request.body); return s.statusPolls }
                let status = statuses[min(poll, statuses.count) - 1]
                var data: [String: Any] = ["status": status, "uploaded_bytes": state.value.receivedBytes]
                if let failReason { data["fail_reason"] = failReason }
                return .json(["data": data, "error": ok])

            default:
                return HTTPServerResponse(status: 404)
            }
        }
    }

    func publisher(preferredChunk: Int64 = TikTokChunkPlan.preferredChunk) throws -> TikTokPublisher {
        TikTokPublisher(tokens: try makeTokens(), apiBaseURL: mock.baseURL, retry: fastRetry,
                        preferredChunkSize: preferredChunk, pollInterval: .milliseconds(10), pollTimeout: .seconds(10))
    }
}

@Suite struct TikTokTests {
    // MARK: Chunk math (developers.tiktok.com/doc/content-posting-api-media-transfer-guide)

    func checkInvariants(_ plan: TikTokChunkPlan) {
        let chunks = plan.chunks
        #expect(Int64(chunks.count) == plan.totalChunkCount)
        #expect(plan.totalChunkCount == plan.videoSize / plan.chunkSize)          // rounded down
        #expect((1...1000).contains(plan.totalChunkCount))
        #expect(chunks.first?.lowerBound == 0)
        #expect(chunks.last?.upperBound == plan.videoSize)
        for (a, b) in zip(chunks, chunks.dropFirst()) { #expect(a.upperBound == b.lowerBound) }
        if chunks.count > 1 {
            for chunk in chunks.dropLast() {
                #expect(Int64(chunk.count) == plan.chunkSize)
                #expect(Int64(chunk.count) >= 5 * 1024 * 1024 && Int64(chunk.count) <= 64_000_000)
            }
            #expect(Int64(chunks.last!.count) >= plan.chunkSize && Int64(chunks.last!.count) <= 128_000_000)
        } else {
            #expect(plan.chunkSize == plan.videoSize && plan.videoSize <= 64_000_000)
        }
    }

    @Test func smallVideosGoInOneChunk() throws {
        for size: Int64 in [1, 3_000_000, 4_194_304, 5 * 1024 * 1024, 50_000_123, 64_000_000] {
            let plan = try TikTokChunkPlan(videoSize: size)
            #expect(plan.totalChunkCount == 1)
            #expect(plan.chunkSize == size)
            checkInvariants(plan)
        }
    }

    @Test func seventyMegabytesSplitsIntoSevenChunksWithTrailingBytesInTheLast() throws {
        let mebibytes = try TikTokChunkPlan(videoSize: 70 * 1024 * 1024)        // 73,400,320 bytes
        #expect(mebibytes.chunkSize == 10_000_000)
        #expect(mebibytes.totalChunkCount == 7)
        #expect(mebibytes.range(ofChunk: 6) == 60_000_000..<73_400_320)          // 13,400,320-byte final chunk
        checkInvariants(mebibytes)

        let decimal = try TikTokChunkPlan(videoSize: 70_000_000)
        #expect(decimal.totalChunkCount == 7)
        #expect(decimal.range(ofChunk: 6).count == 10_000_000)
        checkInvariants(decimal)

        let justOver = try TikTokChunkPlan(videoSize: 64_000_001)
        #expect(justOver.totalChunkCount == 6)
        #expect(justOver.range(ofChunk: 5).count == 14_000_001)
        checkInvariants(justOver)
    }

    @Test func hugeVideosStayWithinAThousandChunks() throws {
        let fourGB = try TikTokChunkPlan(videoSize: 4 << 30)
        #expect(fourGB.totalChunkCount == 429)
        checkInvariants(fourGB)
        let sixtyGB = try TikTokChunkPlan(videoSize: 60_000_000_000)
        #expect(sixtyGB.chunkSize == 60_000_000 && sixtyGB.totalChunkCount == 1000)
        checkInvariants(sixtyGB)
        #expect(throws: PublishError.self) { _ = try TikTokChunkPlan(videoSize: 100_000_000_000) }
        #expect(throws: PublishError.self) { _ = try TikTokChunkPlan(videoSize: 0) }
        // A too-small preferred chunk is raised to the 5 MiB minimum.
        let tiny = try TikTokChunkPlan(videoSize: 100_000_000, preferredChunkSize: 1_000)
        #expect(tiny.chunkSize == 5 * 1024 * 1024)
        checkInvariants(tiny)
    }

    // MARK: Upload flow

    @Test func seventyMegabyteSparseFileUploadsInChunksAndLandsInInbox() async throws {
        let tiktok = try await MockTikTok(fail500OnAttempt: 2)
        defer { tiktok.mock.stop() }
        let size: Int64 = 70 * 1024 * 1024
        let video = try makeSparseFile(name: "clip.mp4", size: size)
        defer { removeTempFile(video) }

        let fractions = Box<[Double]>([])
        let result = try await tiktok.publisher().publish(
            PublishRequest(file: video, title: "Sunset", tags: ["travel", "golden hour"], attributions: ["Song (CC BY)"])
        ) { progress in fractions.update { $0.append(progress.fraction) } }

        let state = tiktok.state.value
        let source = try #require(state.initBody["source_info"] as? [String: Any])
        #expect(source["source"] as? String == "FILE_UPLOAD")
        #expect((source["video_size"] as? NSNumber)?.int64Value == size)
        #expect((source["chunk_size"] as? NSNumber)?.int64Value == 10_000_000)
        #expect((source["total_chunk_count"] as? NSNumber)?.int64Value == 7)
        #expect(state.initHeaders["content-type"] == "application/json; charset=UTF-8")
        #expect(state.initHeaders["authorization"] == "Bearer test-access")

        #expect(state.served500 == 1)                     // chunk 2 failed once and was resent
        #expect(state.putAttempts == 8)
        #expect(state.chunks.map(\.range) == [
            "bytes 0-9999999/73400320", "bytes 10000000-19999999/73400320", "bytes 20000000-29999999/73400320",
            "bytes 30000000-39999999/73400320", "bytes 40000000-49999999/73400320", "bytes 50000000-59999999/73400320",
            "bytes 60000000-73400319/73400320",
        ])
        #expect(state.chunks.allSatisfy { $0.contentType == "video/mp4" && $0.authorization == nil })
        #expect(state.receivedBytes == size)
        let zeros = SHA256.hash(data: Data(count: Int(size)))
        #expect(state.hash.finalize() == zeros)

        #expect(state.statusPolls == 2)
        #expect(state.statusBodies.allSatisfy { $0["publish_id"] as? String == "v_inbox_file~v2.123" })

        #expect(result.platform == .tiktok)
        #expect(result.remoteID == "v_inbox_file~v2.123")
        #expect(result.url == nil)
        #expect(result.status.contains("TikTok inbox"))
        #expect(result.status.contains("TikTok app"))
        #expect(result.status.contains("Sunset #travel #goldenhour"))
        #expect(result.status.contains("Song (CC BY)"))
        #expect(result.status.contains("Unaudited"))
        #expect(fractions.value.last == 1)
    }

    @Test func threeMegabyteFileIsOneWholeUpload() async throws {
        let tiktok = try await MockTikTok(statuses: ["SEND_TO_USER_INBOX"])
        defer { tiktok.mock.stop() }
        let video = try makeTempFile(name: "small.mov", bytes: 3_000_000)
        defer { removeTempFile(video) }
        _ = try await tiktok.publisher().publish(PublishRequest(file: video, title: "Small"), progress: nil)
        let state = tiktok.state.value
        let source = try #require(state.initBody["source_info"] as? [String: Any])
        #expect((source["chunk_size"] as? NSNumber)?.int64Value == 3_000_000)
        #expect((source["total_chunk_count"] as? NSNumber)?.int64Value == 1)
        #expect(state.chunks.map(\.range) == ["bytes 0-2999999/3000000"])
        #expect(state.chunks.first?.contentType == "video/quicktime")
        #expect(state.hash.finalize() == SHA256.hash(data: try Data(contentsOf: video)))
    }

    @Test func failedProcessingIsReported() async throws {
        let tiktok = try await MockTikTok(statuses: ["PROCESSING_UPLOAD", "FAILED"], failReason: "duration_check_failed")
        defer { tiktok.mock.stop() }
        let video = try makeTempFile(name: "bad.mp4", bytes: 1000)
        defer { removeTempFile(video) }
        await #expect(throws: PublishError.publishFailed(platform: .tiktok, reason: "the video's duration isn't allowed")) {
            _ = try await tiktok.publisher().publish(PublishRequest(file: video, title: "x"), progress: nil)
        }
    }

    @Test func initErrorEnvelopeIsSurfaced() async throws {
        let tiktok = try await MockTikTok(initError: "spam_risk_too_many_pending_share")
        defer { tiktok.mock.stop() }
        let video = try makeTempFile(name: "a.mp4", bytes: 1000)
        defer { removeTempFile(video) }
        do {
            _ = try await tiktok.publisher().publish(PublishRequest(file: video, title: "x"), progress: nil)
            Issue.record("expected an error")
        } catch let PublishError.api(platform, code, message) {
            #expect(platform == .tiktok)
            #expect(code == "spam_risk_too_many_pending_share")
            #expect(message.contains("log-2") && message.contains("5 pending"))
        }
        #expect(tiktok.state.value.putAttempts == 0)
    }
}
