@testable import ClipperPublish
import Foundation
import Testing

/// Mock of YouTube's resumable upload + captions endpoints. It only persists part of some chunks (answering 308 with the
/// stored range), fails one chunk with 503 after persisting part of it, and requires every chunk to start exactly where
/// the stored bytes end, like Google's server.
final class MockYouTube: Sendable {
    struct State: Sendable {
        var initHeaders: [String: String] = [:]
        var initQuery: [String: String] = [:]
        var metadata = Data()
        var received = Data()
        var total: Int64 = 0
        var chunkPuts = 0
        var statusQueries = 0
        var served503 = 0
        var log: [String] = []
        var captions: [(query: [String: String], contentType: String, body: Data)] = []
        var badAuth = 0
        var acceptedTokens: Set<String> = ["test-access"]
    }

    let state: Box<State>
    let mock: MockServer

    init(failOnChunk: Int = 3, returnedPrivacy: String = "private") async throws {
        let state = Box(State())
        self.state = state
        mock = try await MockServer { request in
            let auth = request.header("authorization") ?? ""
            guard state.value.acceptedTokens.contains(where: { auth == "Bearer \($0)" }) else {
                state.update { $0.badAuth += 1 }
                return .json(["error": ["code": 401, "message": "Invalid Credentials", "errors": [["reason": "authError"]]]], status: 401)
            }
            let query = Dictionary(request.query.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
            switch (request.method, request.path) {
            case ("POST", "/upload/youtube/v3/videos"):
                state.update {
                    $0.initHeaders = request.headers
                    $0.initQuery = query
                    $0.metadata = request.body
                    $0.total = Int64(request.header("x-upload-content-length") ?? "") ?? -1
                }
                let host = request.header("host") ?? "127.0.0.1"
                return HTTPServerResponse(status: 200, headers: [("Location", "http://\(host)/upload/session/abc?upload_id=xyz")])

            case ("PUT", "/upload/session/abc"):
                guard let range = parseContentRange(request.header("content-range")) else { return HTTPServerResponse(status: 400) }
                return state.update { s -> HTTPServerResponse in
                    guard range.total == s.total else { return HTTPServerResponse(status: 400) }
                    if range.start < 0 {   // status query: "bytes */total"
                        s.statusQueries += 1
                        s.log.append("status")
                    } else {
                        s.chunkPuts += 1
                        s.log.append("put \(range.start)-\(range.end)")
                        guard range.start == Int64(s.received.count), Int64(request.body.count) == range.end - range.start + 1 else {
                            return HTTPServerResponse(status: 400, body: Data("bad range".utf8))
                        }
                        if s.chunkPuts == failOnChunk {
                            // Keep a bit of this chunk, then fail: the client must ask where to resume.
                            s.received.append(request.body.prefix(100_000))
                            s.served503 += 1
                            return HTTPServerResponse(status: 503)
                        }
                        // Every other chunk is only partly persisted.
                        let keep = s.chunkPuts.isMultiple(of: 2) ? request.body.count / 2 : request.body.count
                        s.received.append(request.body.prefix(keep))
                    }
                    if Int64(s.received.count) == s.total {
                        return .json(["id": "vid123", "kind": "youtube#video", "status": ["privacyStatus": returnedPrivacy]])
                    }
                    var headers: [(String, String)] = []
                    if !s.received.isEmpty { headers.append(("Range", "bytes=0-\(s.received.count - 1)")) }
                    return HTTPServerResponse(status: 308, headers: headers)
                }

            case ("POST", "/upload/youtube/v3/captions"):
                state.update { $0.captions.append((query, request.header("content-type") ?? "", request.body)) }
                return .json(["id": "caption-\(state.value.captions.count)", "kind": "youtube#caption"])

            default:
                return HTTPServerResponse(status: 404)
            }
        }
    }

    var uploadBase: URL { mock.url("/upload/youtube/v3") }
}

@Suite struct YouTubeTests {
    @Test func resumableUploadSurvivesPartialRangesAnd503() async throws {
        let youtube = try await MockYouTube()
        defer { youtube.mock.stop() }
        let video = try makeTempFile(name: "clip.mp4", bytes: 1_300_000)
        defer { removeTempFile(video) }
        let dir = video.deletingLastPathComponent()
        let spanish = dir.appendingPathComponent("clip.es.srt")
        let plain = dir.appendingPathComponent("clip.srt")
        try Data("1\n00:00:00,000 --> 00:00:01,000\nHola\n".utf8).write(to: spanish)
        try Data("1\n00:00:00,000 --> 00:00:01,000\nHello\n".utf8).write(to: plain)

        let publisher = YouTubePublisher(tokens: try makeTokens(), uploadBaseURL: youtube.uploadBase,
                                         chunkSize: 256 << 10, retry: fastRetry)
        #expect(await publisher.isConnected())
        let request = PublishRequest(file: video, title: "My clip", description: "Made with Clipper.",
                                     tags: ["#travel", "slow motion", "travel"], visibility: .public,
                                     captions: [.init(url: spanish), .init(url: plain)], attributions: ["Song by Artist (CC BY 4.0)"], isShort: true)
        let fractions = Box<[Double]>([])
        let result = try await publisher.publish(request) { progress in fractions.update { $0.append(progress.fraction) } }

        let state = youtube.state.value
        // Bytes reassembled exactly.
        #expect(state.received == (try Data(contentsOf: video)))
        #expect(state.served503 == 1)
        #expect(state.statusQueries >= 1)
        #expect(state.log.contains("status"))
        #expect(state.chunkPuts > 6)   // 5 full chunks of 256 KiB + re-sends of partial ones

        // Session request.
        #expect(state.initQuery["uploadType"] == "resumable")
        #expect(state.initQuery["part"] == "snippet,status")
        #expect(state.initHeaders["x-upload-content-length"] == "1300000")
        #expect(state.initHeaders["x-upload-content-type"] == "video/mp4")
        #expect(state.initHeaders["content-type"]?.hasPrefix("application/json") == true)

        // Metadata JSON.
        let metadata = jsonObject(state.metadata)
        let snippet = try #require(metadata["snippet"] as? [String: Any])
        let status = try #require(metadata["status"] as? [String: Any])
        #expect(snippet["title"] as? String == "My clip #Shorts")
        #expect(snippet["description"] as? String == "Made with Clipper.\n\nMusic:\nSong by Artist (CC BY 4.0)")
        #expect(snippet["tags"] as? [String] == ["travel", "slow motion"])
        #expect(snippet["categoryId"] as? String == "22")
        #expect(status["privacyStatus"] as? String == "public")
        #expect(status["selfDeclaredMadeForKids"] as? Bool == false)

        // Captions: multipart/related with the snippet JSON then the SRT bytes.
        #expect(state.captions.count == 2)
        for (caption, (language, text)) in zip(state.captions, [("es", "Hola"), ("en", "Hello")]) {
            #expect(caption.query["uploadType"] == "multipart")
            #expect(caption.query["part"] == "snippet")
            #expect(caption.contentType.hasPrefix("multipart/related; boundary="))
            let body = String(decoding: caption.body, as: UTF8.self)
            #expect(body.contains(#""videoId":"vid123""#))
            #expect(body.contains(#""language":"\#(language)""#))
            #expect(body.contains(#""isDraft":false"#))
            #expect(body.contains(text))
            let boundary = caption.contentType.components(separatedBy: "boundary=").last!
            #expect(body.hasPrefix("--\(boundary)\r\n"))
            #expect(body.hasSuffix("--\(boundary)--\r\n"))
        }

        #expect(result.platform == .youtube)
        #expect(result.remoteID == "vid123")
        #expect(result.url == URL(string: "https://youtube.com/shorts/vid123"))
        #expect(result.status.contains("set it to private instead of public"))
        #expect(result.status.contains("unaudited"))
        #expect(result.status.contains("captions es added"))
        #expect(fractions.value.last == 1)
        #expect(zip(fractions.value, fractions.value.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test func refreshesTokenOn401AndUsesYoutuBeURLForRegularVideos() async throws {
        let auth = try await MockAuthServer()
        defer { auth.mock.stop() }
        let youtube = try await MockYouTube(failOnChunk: 0)
        defer { youtube.mock.stop() }
        youtube.state.update { $0.acceptedTokens = ["access-refreshed-1"] }
        let store = InMemoryCredentialStore()
        try store.encode(OAuthToken(accessToken: "revoked", refreshToken: "refresh-1", expiresAt: Date().addingTimeInterval(3600)),
                         for: "youtube.token")
        let tokens = TokenManager(client: OAuthClient(config: auth.config()), store: store, key: "youtube.token")
        let video = try makeTempFile(name: "long.mov", bytes: 300_000)
        defer { removeTempFile(video) }
        let publisher = YouTubePublisher(tokens: tokens, uploadBaseURL: youtube.uploadBase, chunkSize: 1 << 20, retry: fastRetry)
        let result = try await publisher.publish(PublishRequest(file: video, title: "Long one", isShort: false))
        #expect(result.url == URL(string: "https://youtu.be/vid123"))
        #expect(result.status.hasPrefix("Uploaded as private."))
        #expect(youtube.state.value.badAuth == 1)
        #expect(youtube.state.value.initHeaders["x-upload-content-type"] == "video/quicktime")
        #expect(try store.decode(OAuthToken.self, "youtube.token")?.accessToken == "access-refreshed-1")
        #expect(jsonObject(youtube.state.value.metadata)["snippet"].flatMap { ($0 as? [String: Any])?["title"] as? String } == "Long one")
    }

    @Test func notConnectedWithoutToken() async throws {
        let config = OAuthConfig(authorizeURL: URL(string: "http://127.0.0.1:9/a")!, tokenURL: URL(string: "http://127.0.0.1:9/t")!,
                                 clientID: "c", scopes: [])
        let tokens = TokenManager(client: OAuthClient(config: config), store: InMemoryCredentialStore(), key: "youtube.token")
        let publisher = YouTubePublisher(tokens: tokens, uploadBaseURL: URL(string: "http://127.0.0.1:9/upload")!)
        #expect(await !publisher.isConnected())
        let video = try makeTempFile(name: "a.mp4", bytes: 10)
        defer { removeTempFile(video) }
        await #expect(throws: PublishError.notConnected(.youtube)) {
            _ = try await publisher.publish(PublishRequest(file: video, title: "x"), progress: nil)
        }
    }

    @Test func titleRules() {
        let file = URL(fileURLWithPath: "/tmp/fallback-name.mp4")
        func title(_ text: String, short: Bool = true) -> String {
            YouTubePublisher.title(for: PublishRequest(file: file, title: text, isShort: short))
        }
        #expect(title("Hello") == "Hello #Shorts")
        #expect(title("Hello", short: false) == "Hello")
        #expect(title("Already #shorts") == "Already #shorts")
        #expect(title("") == "fallback-name #Shorts")
        #expect(title("a <b> c", short: false) == "a ‹b› c")
        let long = String(repeating: "x", count: 150)
        #expect(title(long) == String(repeating: "x", count: 100))           // no room for #Shorts
        let ninety = String(repeating: "y", count: 92)
        #expect(title(ninety) == ninety + " #Shorts")                         // exactly 100
        #expect(title(ninety + "z") == ninety + "z")                         // 101 with suffix: skipped
    }

    @Test func descriptionKeepsCreditsWhenTruncated() {
        let request = PublishRequest(file: URL(fileURLWithPath: "/tmp/a.mp4"), title: "t",
                                     description: String(repeating: "é", count: 4000), attributions: ["Credit line"])
        let description = YouTubePublisher.description(for: request)
        #expect(description.utf8.count <= 5000)
        #expect(description.hasSuffix("…\n\nMusic:\nCredit line"))
    }

    @Test func captionLanguageFromFileName() {
        let video = URL(fileURLWithPath: "/x/my.video.mp4")
        #expect(YouTubePublisher.captionLanguage(for: URL(fileURLWithPath: "/x/my.video.es.srt"), videoFile: video) == "es")
        #expect(YouTubePublisher.captionLanguage(for: URL(fileURLWithPath: "/x/my.video.srt"), videoFile: video) == "en")
        #expect(YouTubePublisher.captionLanguage(for: URL(fileURLWithPath: "/x/clip.pt-BR.srt")) == "pt-BR")
        #expect(YouTubePublisher.captionLanguage(for: URL(fileURLWithPath: "/x/clip.final.srt")) == "en")
        #expect(YouTubePublisher.captionLanguage(for: URL(fileURLWithPath: "/x/clip.srt")) == "en")
    }

    @Test func rangeHeaderParsing() {
        #expect(YouTubePublisher.nextOffset(fromRange: "bytes=0-999999") == 1_000_000)
        #expect(YouTubePublisher.nextOffset(fromRange: nil) == 0)
        #expect(YouTubePublisher(tokens: try! makeTokens(), chunkSize: 1_000_000).chunkSize == 786_432)   // 3 × 256 KiB
    }
}
