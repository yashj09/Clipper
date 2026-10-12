@testable import ClipperPublish
import Foundation
import Synchronization
import Testing

// MARK: - Mock Instagram Graph API (+ OAuth hosts) sharing a server with the mock bucket

private let igUserID = "17841400000000001"
private let fixedNow = Date(timeIntervalSince1970: 1_790_000_000)

private final class MockInstagram: Sendable {
    struct State {
        /// Status codes returned by successive container polls; the last one repeats.
        var statuses: [String] = ["IN_PROGRESS", "IN_PROGRESS", "FINISHED"]
        var polls = 0
        var publishError: (status: Int, code: Int, message: String)?
        var refreshFails = false
        var quotaUsage = 3
        var shortTokenWrapped = false
        var grantedPermissions = "instagram_business_basic,instagram_business_content_publish"
        /// Object present in the bucket when the container was created (Meta would download it then).
        var objectPresentAtCreate: Bool?
        var log: [String] = []
    }

    let state = Mutex(State())
    let bucket = MockS3Bucket()
    var snapshot: State { state.withLock { $0 } }

    func handle(_ req: PublishMockHTTPServer.Request) -> PublishMockHTTPServer.Response {
        if let s3 = bucket.handle(req) {
            state.withLock { $0.log.append("s3 \(req.method)") }
            return s3
        }
        let v = InstagramEndpoints.defaultVersion
        let path = req.rawPath
        let token = req.method == "GET" ? req.query("access_token") : req.form["access_token"]
        return state.withLock { s -> PublishMockHTTPServer.Response in
            s.log.append("\(req.method) \(path)")
            switch (req.method, path) {
            case ("POST", "/oauth/access_token"):
                let entry: [String: Any] = ["access_token": "short-token", "user_id": 987_654_321,
                                            "permissions": s.grantedPermissions]
                return .json(200, s.shortTokenWrapped ? ["data": [entry]] as [String: Any] : entry)
            case ("GET", "/access_token"):
                guard req.query("access_token") == "short-token" else { return Self.error(400, 190, "bad short token") }
                return .json(200, ["access_token": "long-token", "token_type": "bearer", "expires_in": 5_183_944])
            case ("GET", "/refresh_access_token"):
                if s.refreshFails { return Self.error(400, 190, "cannot refresh") }
                return .json(200, ["access_token": "refreshed-token", "token_type": "bearer", "expires_in": 5_184_000])
            case ("GET", "/\(v)/me"):
                return .json(200, ["user_id": igUserID, "username": "clipper.test", "id": "app-scoped-1"])
            case ("GET", "/\(v)/\(igUserID)/content_publishing_limit"):
                return .json(200, ["data": [["quota_usage": s.quotaUsage, "config": ["quota_total": 100, "quota_duration": 86400]]]])
            case ("POST", "/\(v)/\(igUserID)/media"):
                if let url = req.form["video_url"].flatMap(URL.init(string:)) {
                    let key = url.path.split(separator: "/").dropFirst().joined(separator: "/")
                    s.objectPresentAtCreate = bucket.objects[key] != nil
                }
                return .json(200, ["id": "17900000000000042"])
            case ("GET", "/\(v)/17900000000000042"):
                let code = s.statuses[min(s.polls, s.statuses.count - 1)]
                s.polls += 1
                return .json(200, ["status_code": code, "status": code == "ERROR" ? "Error: unsupported video codec" : code,
                                   "id": "17900000000000042"])
            case ("POST", "/\(v)/\(igUserID)/media_publish"):
                if let e = s.publishError { return Self.error(e.status, e.code, e.message) }
                guard req.form["creation_id"] == "17900000000000042" else { return Self.error(400, 100, "bad creation id") }
                return .json(200, ["id": "17950000000000099"])
            case ("GET", "/\(v)/17950000000000099"):
                return .json(200, ["permalink": "https://www.instagram.com/reel/CLIPPERTEST/", "id": "17950000000000099"])
            default:
                return Self.error(404, 803, "unknown path \(path) (token \(token ?? "-"))")
            }
        }
    }

    static func error(_ status: Int, _ code: Int, _ message: String) -> PublishMockHTTPServer.Response {
        .json(status, ["error": ["message": message, "type": "OAuthException", "code": code, "fbtrace_id": "x"]])
    }
}

private struct Harness {
    let mock: MockInstagram
    let server: PublishMockHTTPServer
    let store: InMemoryCredentialStore
    var endpoints: InstagramEndpoints { .mock(server.baseURL) }

    static func make(tokenAge: TimeInterval = 5 * 24 * 3600, withToken: Bool = true, withStorage: Bool = true) async throws -> Harness {
        let mock = MockInstagram()
        let server = try await PublishMockHTTPServer { mock.handle($0) }
        let store = InMemoryCredentialStore()
        if withToken {
            let issued = fixedNow.addingTimeInterval(-tokenAge)
            try store.encode(InstagramToken(userID: igUserID, username: "clipper.test", accessToken: "stored-token",
                                            issuedAt: issued, expiresAt: issued.addingTimeInterval(60 * 24 * 3600)),
                             for: InstagramCredentialKeys.token)
        }
        if withStorage { try store.encode(mock.bucket.config(server), for: InstagramCredentialKeys.storage) }
        return Harness(mock: mock, server: server, store: store)
    }

    func publisher(facts: InstagramReels.VideoFacts = .init(duration: 30, width: 1080, height: 1920),
                   timeout: Duration = .seconds(10)) -> InstagramPublisher {
        InstagramPublisher(credentials: store, endpoints: endpoints, session: publishTestSession(),
                           options: .init(pollInterval: .milliseconds(5), maxPollInterval: .milliseconds(20),
                                          processingTimeout: timeout,
                                          storage: .init(multipartThreshold: 64 * 1024, partSize: 16 * 1024,
                                                         retryDelay: .milliseconds(5))),
                           probe: { _ in facts }, now: { fixedNow })
    }

    var auth: InstagramAuth { InstagramAuth(credentials: store, endpoints: endpoints, session: publishTestSession(), now: { fixedNow }) }
}

private func reelRequest(_ file: URL, visibility: Visibility = .public) -> PublishRequest {
    PublishRequest(file: file, title: "Best moment", description: "From last night's stream.",
                   tags: ["gaming", "#clips", "Gaming", "best-of"], visibility: visibility,
                   attributions: ["\"Song\" by Artist (CC BY 4.0)"])
}

private final class StageLog: Sendable {
    private let values = Mutex<[UploadProgress]>([])
    var all: [UploadProgress] { values.withLock { $0 } }
    var callback: @Sendable (UploadProgress) -> Void { { [self] p in values.withLock { $0.append(p) } } }
}

// MARK: - Tests

@Suite("Instagram")
struct InstagramTests {
    // MARK: Full flow

    @Test func fullFlowPublishesReelAndDeletesTemporaryObject() async throws {
        let h = try await Harness.make()
        let file = try publishTempFile(bytes: 100 * 1024)   // > threshold → multipart
        defer { try? FileManager.default.removeItem(at: file) }
        let stages = StageLog()

        let result = try await h.publisher().publish(reelRequest(file), progress: stages.callback)

        #expect(result.platform == .instagram)
        #expect(result.remoteID == "17950000000000099")
        #expect(result.url == URL(string: "https://www.instagram.com/reel/CLIPPERTEST/"))
        #expect(result.status.hasPrefix("published as a Reel (also shared to feed)"))

        let snap = h.mock.snapshot
        #expect(snap.polls == 3)
        #expect(snap.objectPresentAtCreate == true)
        let bucket = h.mock.bucket.snapshot
        #expect(bucket.signatureFailures.isEmpty)
        #expect(bucket.objects.isEmpty, "temporary object must be deleted")
        #expect(bucket.completed.count == 1)
        #expect(bucket.deleted.count == 1 && bucket.deleted[0].hasPrefix("clipper-tmp/"))

        // Request order: quota → upload → container → polls → publish → permalink → delete.
        let graph = snap.log.filter { !$0.hasPrefix("s3") }
        let v = InstagramEndpoints.defaultVersion
        #expect(graph == ["GET /\(v)/\(igUserID)/content_publishing_limit", "POST /\(v)/\(igUserID)/media"]
                + Array(repeating: "GET /\(v)/17900000000000042", count: 3)
                + ["POST /\(v)/\(igUserID)/media_publish", "GET /\(v)/17950000000000099"])
        #expect(snap.log.last == "s3 DELETE")

        let create = try #require(h.server.requests.first { $0.rawPath == "/\(v)/\(igUserID)/media" })
        let form = create.form
        #expect(form["media_type"] == "REELS")
        #expect(form["share_to_feed"] == "true")
        #expect(form["access_token"] == "stored-token")
        let videoURL = try #require(form["video_url"])
        #expect(videoURL.hasPrefix("\(h.server.baseURL.absoluteString)/clips/clipper-tmp/"))
        #expect(videoURL.contains("X-Amz-Expires=3600&") && videoURL.contains("X-Amz-Signature="))
        #expect(form["caption"] == "Best moment\n\nFrom last night's stream.\n\nMusic:\n\"Song\" by Artist (CC BY 4.0)\n\n#gaming #clips #bestof")
        let poll = try #require(h.server.requests.first { $0.rawPath == "/\(v)/17900000000000042" })
        #expect(poll.query("fields") == "status_code,status")

        let fractions = stages.all.map(\.fraction)
        #expect(fractions == fractions.sorted() && fractions.first == 0 && fractions.last == 1)
    }

    @Test func publishFailureStillDeletesTemporaryObject() async throws {
        let h = try await Harness.make()
        h.mock.state.withLock { $0.publishError = (400, 9, "Application request limit reached") }
        let file = try publishTempFile(bytes: 20 * 1024)
        defer { try? FileManager.default.removeItem(at: file) }

        await #expect(throws: InstagramError.api(status: 400, code: 9, subcode: nil, message: "Application request limit reached")) {
            try await h.publisher().publish(reelRequest(file), progress: nil)
        }
        let bucket = h.mock.bucket.snapshot
        #expect(bucket.objects.isEmpty)
        #expect(bucket.deleted.count == 1)
        #expect(h.mock.snapshot.log.last == "s3 DELETE")
    }

    @Test func containerErrorFailsAndDeletes() async throws {
        let h = try await Harness.make()
        h.mock.state.withLock { $0.statuses = ["IN_PROGRESS", "ERROR"] }
        let file = try publishTempFile(bytes: 20 * 1024)
        defer { try? FileManager.default.removeItem(at: file) }

        await #expect(throws: InstagramError.processingFailed(statusCode: "ERROR", status: "Error: unsupported video codec")) {
            try await h.publisher().publish(reelRequest(file), progress: nil)
        }
        #expect(!h.mock.snapshot.log.contains { $0.hasSuffix("/media_publish") })
        #expect(h.mock.bucket.objects.isEmpty)
    }

    @Test func processingTimeoutFailsAndDeletes() async throws {
        let h = try await Harness.make()
        h.mock.state.withLock { $0.statuses = ["IN_PROGRESS"] }
        let file = try publishTempFile(bytes: 20 * 1024)
        defer { try? FileManager.default.removeItem(at: file) }

        await #expect(throws: InstagramError.processingTimedOut(seconds: 1)) {
            try await h.publisher(timeout: .milliseconds(150)).publish(reelRequest(file), progress: nil)
        }
        #expect(h.mock.snapshot.polls >= 3)
        #expect(h.mock.bucket.objects.isEmpty)
    }

    @Test func uploadFailureStillAttemptsDelete() async throws {
        let h = try await Harness.make()
        h.mock.bucket.state.withLock { $0.failPart = (2, 403, 100) }
        let file = try publishTempFile(bytes: 100 * 1024)
        defer { try? FileManager.default.removeItem(at: file) }

        await #expect(throws: S3Error.self) { try await h.publisher().publish(reelRequest(file), progress: nil) }
        let bucket = h.mock.bucket.snapshot
        #expect(bucket.aborted.count == 1 && bucket.deleted.count == 1 && bucket.objects.isEmpty)
        #expect(!h.mock.snapshot.log.contains { $0.hasSuffix("/media") })
    }

    @Test func quotaExhaustedStopsBeforeUpload() async throws {
        let h = try await Harness.make()
        h.mock.state.withLock { $0.quotaUsage = 100 }
        let file = try publishTempFile(bytes: 1024)
        defer { try? FileManager.default.removeItem(at: file) }

        await #expect(throws: InstagramError.quotaExceeded(used: 100, total: 100)) {
            try await h.publisher().publish(reelRequest(file), progress: nil)
        }
        #expect(h.mock.bucket.snapshot.operations.isEmpty)
    }

    // MARK: Validation

    @Test func validationErrorsBeforeAnyNetworkCall() async throws {
        let h = try await Harness.make()
        let file = try publishTempFile(bytes: 1024, ext: "avi")
        defer { try? FileManager.default.removeItem(at: file) }

        let publisher = h.publisher(facts: .init(duration: 2, width: 2160, height: 3840))
        await #expect {
            try await publisher.publish(reelRequest(file, visibility: .private), progress: nil)
        } throws: { error in
            guard case let .validation(problems) = error as? InstagramError else { return false }
            return problems.count == 4
                && problems.contains { $0.contains("always public") }
                && problems.contains { $0.contains("MP4 or MOV") }
                && problems.contains { $0.contains("at least 3 s") }
                && problems.contains { $0.contains("2160 px wide") }
        }
        #expect(h.server.requests.isEmpty)
    }

    @Test func reelLimits() throws {
        let ok = InstagramReels.check(fileExtension: "MP4", fileSize: 50_000_000,
                                      facts: .init(duration: 60, width: 1080, height: 1920), visibility: .public)
        #expect(ok.problems.isEmpty && ok.notes.isEmpty)
        let long = InstagramReels.check(fileExtension: "mov", fileSize: 300_000_001,
                                        facts: .init(duration: 901, width: 1920, height: 1080), visibility: .public)
        #expect(long.problems.count == 2)   // too long, too big
        #expect(long.notes == ["aspect ratio 1920:1080 is not the recommended 9:16"])
        let extreme = InstagramReels.check(fileExtension: "mp4", fileSize: 1, facts: .init(duration: 3, width: 1900, height: 100),
                                           visibility: .public)
        #expect(extreme.problems == ["aspect ratio 1900:100 is outside 0.01:1 – 10:1"])
    }

    @Test func oversizedFileRejected() async throws {
        let h = try await Harness.make()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("clipper-big-\(UUID().uuidString).mp4")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 301 * 1_000_000)   // sparse
        try handle.close()

        await #expect(throws: InstagramError.validation(["file is 301 MB; Reels allow at most 300 MB — export at a lower bitrate"])) {
            try await h.publisher().publish(reelRequest(file), progress: nil)
        }
        #expect(h.server.requests.isEmpty)
    }

    @Test func notConnectedStates() async throws {
        let file = try publishTempFile(bytes: 1024)
        defer { try? FileManager.default.removeItem(at: file) }

        let noToken = try await Harness.make(withToken: false)
        #expect(await noToken.publisher().isConnected() == false)
        await #expect { try await noToken.publisher().publish(reelRequest(file), progress: nil) } throws: { error in
            if case .notConnected = error as? InstagramError { return true } else { return false }
        }
        let noStorage = try await Harness.make(withStorage: false)
        #expect(await noStorage.publisher().isConnected() == false)
        await #expect { try await noStorage.publisher().publish(reelRequest(file), progress: nil) } throws: { error in
            guard case let .notConnected(why) = error as? InstagramError else { return false }
            return why.contains("storage.s3")
        }
        let expired = try await Harness.make(tokenAge: 61 * 24 * 3600)
        #expect(await expired.publisher().isConnected() == false)
        await #expect { try await expired.publisher().publish(reelRequest(file), progress: nil) } throws: { error in
            guard case let .notConnected(why) = error as? InstagramError else { return false }
            return why.contains("expired")
        }
        #expect(expired.server.requests.isEmpty)
        let connected = try await Harness.make()
        #expect(await connected.publisher().isConnected())
    }

    // MARK: Caption

    @Test func captionAssembly() throws {
        let caption = try InstagramCaption.build(title: " Title ", description: "Body text #already",
                                                 attributions: ["Credit A", "Credit B"], tags: ["already", "new tag", "ünïcode", "", "#new_tag", "NEWTAG"])
        #expect(caption == "Title\n\nBody text #already\n\nMusic:\nCredit A\nCredit B\n\n#newtag #ünïcode #new_tag")
        #expect(try InstagramCaption.build(title: "Only", description: "", attributions: [], tags: []) == "Only")
        #expect(InstagramCaption.hashtags(from: ["a b", "A-B", "c!"]) == ["#ab", "#c"])
    }

    @Test func captionTruncationKeepsCredits() throws {
        let credits = ["\"Track\" by Someone — CC BY 4.0 — https://example.com/track"]
        let longDescription = String(repeating: "word ", count: 600)   // 3000 chars
        let caption = try InstagramCaption.build(title: "Title", description: longDescription, attributions: credits,
                                                 tags: ["one", "two"])
        #expect(caption.utf16.count <= 2200)
        #expect(caption.hasPrefix("Title\n\nword word"))
        #expect(caption.contains("…\n\nMusic:\n" + credits[0] + "\n\n#one #two"))
        #expect(caption.hasSuffix("#two"))

        // A title too long on its own: description dropped, hashtags dropped, title shortened; credits survive.
        let hugeTitle = String(repeating: "T", count: 3000)
        let squeezed = try InstagramCaption.build(title: hugeTitle, description: "desc", attributions: credits, tags: ["x"])
        #expect(squeezed.utf16.count <= 2200)
        #expect(squeezed.hasSuffix("…\n\nMusic:\n" + credits[0]))
        #expect(!squeezed.contains("desc") && !squeezed.contains("#x"))

        // Emoji count as two UTF-16 units; truncation never splits them.
        let emoji = try InstagramCaption.build(title: "", description: String(repeating: "😀", count: 2000), attributions: [], tags: [],
                                               maxLength: 101)
        #expect(emoji.utf16.count <= 101 && emoji.hasSuffix("😀…"))
    }

    @Test func captionLimitsAreValidationErrors() throws {
        let tooManyTags = (1...31).map { "#t\($0)" }.joined(separator: " ")
        #expect(throws: InstagramError.self) {
            try InstagramCaption.build(title: "", description: tooManyTags, attributions: [], tags: [])
        }
        // 30 existing hashtags leave no room for tag-derived ones.
        let thirty = (1...30).map { "#t\($0)" }.joined(separator: " ")
        #expect(try InstagramCaption.build(title: "", description: thirty, attributions: [], tags: ["extra"]) == thirty)

        let mentions = (1...21).map { "@user\($0)" }.joined(separator: " ")
        #expect(throws: InstagramError.self) {
            try InstagramCaption.build(title: "", description: mentions, attributions: [], tags: [])
        }
        // Emails aren't mentions.
        let emails = (1...25).map { "a\($0)@example.com" }.joined(separator: " ")
        _ = try InstagramCaption.build(title: "", description: emails, attributions: [], tags: [])

        #expect(throws: InstagramError.self) {
            try InstagramCaption.build(title: "", description: "", attributions: [String(repeating: "c", count: 2300)], tags: [])
        }
    }

    // MARK: Tokens

    @Test func oldTokenIsRefreshedBeforePublishing() async throws {
        let h = try await Harness.make(tokenAge: 51 * 24 * 3600)
        let file = try publishTempFile(bytes: 1024)
        defer { try? FileManager.default.removeItem(at: file) }

        _ = try await h.publisher().publish(reelRequest(file), progress: nil)
        let refresh = try #require(h.server.requests.first { $0.rawPath == "/refresh_access_token" })
        #expect(refresh.query("grant_type") == "ig_refresh_token")
        #expect(refresh.query("access_token") == "stored-token")
        let stored = try #require(try h.auth.storedToken())
        #expect(stored.accessToken == "refreshed-token")
        #expect(stored.issuedAt == fixedNow)
        #expect(stored.expiresAt == fixedNow.addingTimeInterval(5_184_000))
        let create = try #require(h.server.requests.first { $0.rawPath.hasSuffix("/media") })
        #expect(create.form["access_token"] == "refreshed-token")
    }

    @Test func recentTokenIsNotRefreshed() async throws {
        let h = try await Harness.make(tokenAge: 49 * 24 * 3600)
        let (token, warning) = try await h.auth.validToken()
        #expect(token.accessToken == "stored-token" && warning == nil)
        #expect(h.server.requests.isEmpty)
    }

    @Test func failedRefreshOfValidTokenIsAWarning() async throws {
        let h = try await Harness.make(tokenAge: 55 * 24 * 3600)
        h.mock.state.withLock { $0.refreshFails = true }
        let file = try publishTempFile(bytes: 1024)
        defer { try? FileManager.default.removeItem(at: file) }

        let result = try await h.publisher().publish(reelRequest(file), progress: nil)
        #expect(result.status.contains("token refresh failed"))
        #expect(try h.auth.storedToken()?.accessToken == "stored-token")
    }

    // MARK: Login

    private func configureApp(_ store: InMemoryCredentialStore, redirect: String = "https://localhost:8443/") throws {
        try store.setString("1234567890", for: InstagramCredentialKeys.appID)
        try store.setString("app-secret-xyz", for: InstagramCredentialKeys.appSecret)
        try store.setString(redirect, for: InstagramCredentialKeys.redirectURI)
    }

    @Test func authorizeURLHasDocumentedParameters() throws {
        let store = InMemoryCredentialStore()
        try configureApp(store)
        let url = try InstagramAuth(credentials: store).authorizeURL(state: "st4te")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "www.instagram.com" && components.path == "/oauth/authorize")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["client_id"] == "1234567890")
        #expect(items["redirect_uri"] == "https://localhost:8443/")
        #expect(items["response_type"] == "code")
        #expect(items["scope"] == "instagram_business_basic,instagram_business_content_publish")
        #expect(items["state"] == "st4te")
        #expect(url.absoluteString.contains("redirect_uri=https%3A%2F%2Flocalhost%3A8443%2F"))

        try store.setString("http://127.0.0.1:9000/cb", for: InstagramCredentialKeys.redirectURI)
        #expect(throws: InstagramError.self) { try InstagramAuth(credentials: store).authorizeURL(state: "s") }
        #expect(InstagramAuth.makeState().count == 32)
    }

    @Test func pastedRedirectParsing() throws {
        #expect(try InstagramAuth.authorizationCode(fromPasted: " https://localhost:8443/?code=AQBx-yz_9#_ \n", expectedState: nil) == "AQBx-yz_9")
        #expect(try InstagramAuth.authorizationCode(fromPasted: "https://localhost:8443/?code=abc&state=s1#_", expectedState: "s1") == "abc")
        #expect(try InstagramAuth.authorizationCode(fromPasted: "AQBcode#_", expectedState: "s1") == "AQBcode")
        #expect(throws: InstagramError.authorization("state mismatch — start the login again")) {
            try InstagramAuth.authorizationCode(fromPasted: "https://localhost:8443/?code=abc&state=evil", expectedState: "s1")
        }
        #expect(throws: InstagramError.authorization("Permissions error")) {
            try InstagramAuth.authorizationCode(fromPasted: "https://localhost:8443/?error=access_denied&error_reason=user_denied&error_description=Permissions+error",
                                                expectedState: nil)
        }
        #expect(throws: InstagramError.self) {
            try InstagramAuth.authorizationCode(fromPasted: "https://localhost:8443/?foo=bar", expectedState: nil)
        }
    }

    @Test(arguments: [false, true])
    func codeExchangeStoresLongLivedToken(wrapped: Bool) async throws {
        let h = try await Harness.make(withToken: false)
        h.mock.state.withLock { $0.shortTokenWrapped = wrapped }
        try configureApp(h.store)

        let token = try await h.auth.connect(pastedRedirect: "https://localhost:8443/?code=THECODE&state=s#_", expectedState: "s")
        #expect(token == InstagramToken(userID: igUserID, username: "clipper.test", accessToken: "long-token",
                                        issuedAt: fixedNow, expiresAt: fixedNow.addingTimeInterval(5_183_944)))
        #expect(try h.auth.storedToken() == token)

        let exchange = try #require(h.server.requests.first { $0.rawPath == "/oauth/access_token" })
        #expect(exchange.method == "POST")
        #expect(exchange.form == ["client_id": "1234567890", "client_secret": "app-secret-xyz",
                                  "grant_type": "authorization_code", "redirect_uri": "https://localhost:8443/", "code": "THECODE"])
        let long = try #require(h.server.requests.first { $0.rawPath == "/access_token" })
        #expect(long.query("grant_type") == "ig_exchange_token" && long.query("client_secret") == "app-secret-xyz")
        let me = try #require(h.server.requests.first { $0.rawPath.hasSuffix("/me") })
        #expect(me.query("fields") == "user_id,username" && me.query("access_token") == "long-token")
    }

    @Test func missingPublishPermissionIsRejected() async throws {
        let h = try await Harness.make(withToken: false)
        h.mock.state.withLock { $0.grantedPermissions = "instagram_business_basic" }
        try configureApp(h.store)
        await #expect(throws: InstagramError.authorization("the content publishing permission was not granted")) {
            try await h.auth.exchange(code: "c")
        }
        #expect(try h.auth.storedToken() == nil)
    }

    @Test func dashboardTokenIsStoredWithAccountID() async throws {
        let h = try await Harness.make(withToken: false)
        let token = try await h.auth.storeDashboardToken(" long-token \n")
        #expect(token.userID == igUserID && token.accessToken == "long-token")
        #expect(token.expiresAt == fixedNow.addingTimeInterval(60 * 24 * 3600))
    }

    @Test func temporaryKeysAreUniqueAndSafe() {
        let a = InstagramPublisher.temporaryKey(prefix: "clipper-tmp/", file: URL(fileURLWithPath: "/x/My Clip (final) #1.mp4"))
        let b = InstagramPublisher.temporaryKey(prefix: "clipper-tmp/", file: URL(fileURLWithPath: "/x/My Clip (final) #1.mp4"))
        #expect(a != b)
        #expect(a.hasPrefix("clipper-tmp/") && a.hasSuffix("/My_Clip__final___1.mp4"))
    }
}
