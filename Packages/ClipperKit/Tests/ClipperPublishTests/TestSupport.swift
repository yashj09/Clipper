@testable import ClipperPublish
import Foundation
import Synchronization

/// An in-process mock HTTP server on 127.0.0.1 (the same loopback server the OAuth flow uses). No test talks to a real
/// platform: every base URL points here.
final class MockServer: Sendable {
    let server: LoopbackHTTPServer
    let port: UInt16
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    init(_ handler: @escaping LoopbackHTTPServer.Handler) async throws {
        server = LoopbackHTTPServer(handler: handler)
        port = try await server.start()
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }
    func stop() { server.stop() }
}

/// Thread-safe mutable box for test state shared with server handlers.
final class Box<Value: Sendable>: Sendable {
    private let storage: Mutex<Value>
    init(_ value: Value) { storage = Mutex(value) }
    var value: Value { storage.withLock { $0 } }
    @discardableResult func update<R: Sendable>(_ body: (inout Value) -> R) -> R { storage.withLock { body(&$0) } }
}

/// Parses an application/x-www-form-urlencoded body.
func formFields(_ body: Data) -> [String: String] {
    var components = URLComponents()
    components.percentEncodedQuery = String(decoding: body, as: UTF8.self)
    return Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
}

func jsonObject(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

let fastRetry = RetryPolicy(maxRetries: 4, baseDelay: .milliseconds(5), maxDelay: .milliseconds(20))

/// A token manager holding a long-lived token, pointed at a mock token endpoint (unused unless a test forces a refresh).
func makeTokens(store: any CredentialStore = InMemoryCredentialStore(), key: String = "test.token",
                tokenURL: URL = URL(string: "http://127.0.0.1:9/token")!, accessToken: String = "test-access") throws -> TokenManager {
    let config = OAuthConfig(authorizeURL: URL(string: "http://127.0.0.1:9/authorize")!, tokenURL: tokenURL,
                             clientID: "client", scopes: ["scope"])
    try store.encode(OAuthToken(accessToken: accessToken, refreshToken: "refresh", expiresAt: Date().addingTimeInterval(3600)),
                     for: key)
    return TokenManager(client: OAuthClient(config: config), store: store, key: key)
}

/// A temp file with `count` bytes of deterministic pseudo-random content.
func makeTempFile(name: String, bytes count: Int, seed: UInt64 = 42) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ClipperPublishTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var state = seed
    var data = Data(count: count)
    data.withUnsafeMutableBytes { buffer in
        for index in 0..<count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            buffer[index] = UInt8(truncatingIfNeeded: state >> 33)
        }
    }
    let url = dir.appendingPathComponent(name)
    try data.write(to: url)
    return url
}

/// A sparse file of `size` bytes (all zeros) that takes no disk space.
func makeSparseFile(name: String, size: Int64) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ClipperPublishTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(size))
    try handle.close()
    return url
}

func removeTempFile(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

/// Parses "bytes a-b/total" or "bytes */total".
func parseContentRange(_ header: String?) -> (start: Int64, end: Int64, total: Int64)? {
    guard let header, header.hasPrefix("bytes ") else { return nil }
    let spec = header.dropFirst(6)
    let parts = spec.split(separator: "/")
    guard parts.count == 2, let total = Int64(parts[1]) else { return nil }
    if parts[0] == "*" { return (-1, -1, total) }
    let bounds = parts[0].split(separator: "-")
    guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]) else { return nil }
    return (start, end, total)
}
