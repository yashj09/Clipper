import Foundation
import Testing
@testable import ClipperPublish

/// Fails the first requests to a path with scripted URL errors, then answers 200.
final class FlakyURLProtocol: URLProtocol, @unchecked Sendable {
    static let plans = Box<[String: [URLError.Code]]>([:])
    static let hits = Box<[String: Int]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        Self.hits.update { $0[url.path, default: 0] += 1 }
        let failure = Self.plans.update { plans -> URLError.Code? in
            guard var steps = plans[url.path], !steps.isEmpty else { return nil }
            let step = steps.removeFirst()
            plans[url.path] = steps
            return step
        }
        if let failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("ok".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite struct HTTPRetryTests {
    let client: HTTPClient = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FlakyURLProtocol.self]
        return HTTPClient(session: URLSession(configuration: configuration))
    }()

    /// Sends `method` to a fresh path that first fails with `failures`; returns (succeeded, attempts).
    func send(_ method: String, failingWith failures: [URLError.Code]) async -> (Bool, Int) {
        let path = "/\(UUID().uuidString)"
        FlakyURLProtocol.plans.update { $0[path] = failures }
        let ok = (try? await client.sendWithRetry(fastRetry, body: method == "GET" ? nil : Data("x".utf8)) {
            var request = URLRequest(url: URL(string: "http://flaky.test\(path)")!)
            request.httpMethod = method
            return request
        }) != nil
        return (ok, FlakyURLProtocol.hits.value[path] ?? 0)
    }

    @Test func postIsNotResentAfterAnAmbiguousFailure() async {
        // The server may have processed it (one-time code redeemed, TikTok upload created): surface the error instead.
        for code in [URLError.Code.networkConnectionLost, .timedOut] {
            let (ok, attempts) = await send("POST", failingWith: [code])
            #expect(!ok)
            #expect(attempts == 1)
        }
    }

    @Test func postIsResentWhenItNeverLeft() async {
        let (ok, attempts) = await send("POST", failingWith: [.cannotConnectToHost, .dnsLookupFailed])
        #expect(ok)
        #expect(attempts == 3)
    }

    @Test func idempotentRequestsAreRetried() async {
        for method in ["PUT", "GET"] {
            let (ok, attempts) = await send(method, failingWith: [.networkConnectionLost, .timedOut])
            #expect(ok)
            #expect(attempts == 3)
        }
    }
}
