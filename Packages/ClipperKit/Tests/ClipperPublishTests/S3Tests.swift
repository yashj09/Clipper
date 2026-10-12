@testable import ClipperPublish
import CryptoKit
import Foundation
import Network
import Synchronization
import Testing

// MARK: - In-process HTTP server (shared by S3Tests and InstagramTests)

/// A tiny HTTP/1.1 server on 127.0.0.1 (random port). Every request is answered by `handler`; nothing leaves the
/// machine.
final class PublishMockHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        var method: String
        /// Raw request target: encoded path plus optional `?query`.
        var target: String
        /// Lowercased header names.
        var headers: [String: String]
        var body: Data

        var rawPath: String { String(target.split(separator: "?", maxSplits: 1).first ?? "") }
        var rawQuery: String {
            let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            return parts.count == 2 ? String(parts[1]) : ""
        }
        /// Decoded query items, in order.
        var queryItems: [(name: String, value: String)] { Self.decodeForm(rawQuery) }
        func query(_ name: String) -> String? { queryItems.first { $0.name == name }?.value }
        var form: [String: String] {
            Dictionary(Self.decodeForm(String(decoding: body, as: UTF8.self)).map { ($0.name, $0.value) }) { a, _ in a }
        }

        static func decodeForm(_ s: String) -> [(name: String, value: String)] {
            s.split(separator: "&").map { pair in
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                func dec(_ x: Substring) -> String {
                    String(x).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(x)
                }
                return (dec(kv[0]), kv.count > 1 ? dec(kv[1]) : "")
            }
        }
    }

    struct Response: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()
        static func json(_ status: Int, _ object: Any) -> Response {
            Response(status: status, headers: ["Content-Type": "application/json"],
                     body: try! JSONSerialization.data(withJSONObject: object))
        }
        static func xml(_ status: Int, _ text: String) -> Response {
            Response(status: status, headers: ["Content-Type": "application/xml"], body: Data(text.utf8))
        }
    }

    typealias Handler = @Sendable (Request) -> Response

    private let listener: NWListener
    private let queue = DispatchQueue(label: "PublishMockHTTPServer")
    private let handler: Handler
    private let log = Mutex<[Request]>([])
    private(set) var port: UInt16 = 0

    var requests: [Request] { log.withLock { $0 } }
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

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

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                log.withLock { $0.append(request) }
                let response = handler(request)
                var head = "HTTP/1.1 \(response.status) \(response.status < 300 ? "OK" : "Error")\r\n"
                for (k, v) in response.headers { head += "\(k): \(v)\r\n" }
                head += "Content-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(head.utf8) + response.body, contentContext: .finalMessage, isComplete: true,
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
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { continue }
            headers[kv[0].lowercased()] = kv[1].trimmingCharacters(in: .whitespaces)
        }
        let rest = Data(buffer[split.upperBound...])
        let body: Data
        if headers["transfer-encoding"]?.lowercased() == "chunked" {
            guard let decoded = decodeChunked(rest) else { return nil }
            body = decoded
        } else {
            let length = Int(headers["content-length"] ?? "0") ?? 0
            guard rest.count >= length else { return nil }
            body = rest.prefix(length)
        }
        return Request(method: String(parts[0]), target: String(parts[1]), headers: headers, body: body)
    }

    /// nil until the terminating zero-size chunk has arrived.
    private static func decodeChunked(_ data: Data) -> Data? {
        var out = Data()
        var index = data.startIndex
        while true {
            guard let lineEnd = data[index...].firstRange(of: Data("\r\n".utf8)) else { return nil }
            let sizeText = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self)
            guard let size = Int(sizeText.split(separator: ";").first ?? "", radix: 16) else { return nil }
            let start = lineEnd.upperBound
            if size == 0 { return out }
            guard data.distance(from: start, to: data.endIndex) >= size + 2 else { return nil }
            let end = data.index(start, offsetBy: size)
            out.append(data[start..<end])
            index = data.index(end, offsetBy: 2)
        }
    }
}

// MARK: - Mock S3 bucket

/// In-memory S3 semantics: PUT/GET/DELETE objects, multipart create/upload/complete/abort. Every request's SigV4
/// signature (header or presigned query) is re-verified with the known secret.
final class MockS3Bucket: Sendable {
    struct State {
        var objects: [String: Data] = [:]
        var contentTypes: [String: String] = [:]
        var uploads: [String: [Int: Data]] = [:]
        var aborted: [String] = []
        var completed: [String] = []
        var deleted: [String] = []
        var signatureFailures: [String] = []
        /// (partNumber, status, remaining times) failure injection for UploadPart.
        var failPart: (number: Int, status: Int, times: Int)?
        var operations: [String] = []
    }

    let bucket: String
    let accessKeyID = "AKIDMOCK"
    let secret = "mock/secret+key"
    let region = "auto"
    let state = Mutex(State())

    init(bucket: String = "clips") { self.bucket = bucket }

    func config(_ server: PublishMockHTTPServer) -> S3Config {
        S3Config(endpoint: server.baseURL, region: region, bucket: bucket, accessKeyID: accessKeyID,
                 secretAccessKey: secret, pathStyle: true)
    }

    var objects: [String: Data] { state.withLock { $0.objects } }
    var snapshot: State { state.withLock { $0 } }

    private static let amzDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()

    /// Returns nil when the request is not addressed to this bucket.
    func handle(_ req: PublishMockHTTPServer.Request) -> PublishMockHTTPServer.Response? {
        let prefix = "/\(bucket)/"
        guard req.rawPath.hasPrefix(prefix) else { return nil }
        let key = String(req.rawPath.dropFirst(prefix.count)).removingPercentEncoding ?? ""
        if let problem = verifySignature(req) {
            state.withLock { $0.signatureFailures.append("\(req.method) \(req.target): \(problem)") }
            return .xml(403, "<Error><Code>SignatureDoesNotMatch</Code><Message>\(problem)</Message></Error>")
        }
        let q = req.query
        return state.withLock { s -> PublishMockHTTPServer.Response in
            switch req.method {
            case "POST" where q("uploads") != nil:
                let id = "upload-\(s.uploads.count + s.aborted.count + s.completed.count + 1)"
                s.uploads[id] = [:]
                s.contentTypes[key] = req.headers["content-type"]
                s.operations.append("create")
                return .xml(200, "<InitiateMultipartUploadResult><Bucket>\(bucket)</Bucket><Key>\(key)</Key><UploadId>\(id)</UploadId></InitiateMultipartUploadResult>")
            case "PUT" where q("uploadId") != nil:
                let id = q("uploadId")!, number = Int(q("partNumber") ?? "") ?? -1
                s.operations.append("part\(number)")
                guard s.uploads[id] != nil else { return .xml(404, "<Error><Code>NoSuchUpload</Code></Error>") }
                if let fail = s.failPart, fail.number == number, fail.times > 0 {
                    s.failPart?.times -= 1
                    return .xml(fail.status, "<Error><Code>InjectedFailure</Code><Message>part \(number)</Message></Error>")
                }
                guard req.headers["x-amz-content-sha256"] == SigV4Signer.sha256Hex(req.body) else {
                    return .xml(400, "<Error><Code>XAmzContentSHA256Mismatch</Code></Error>")
                }
                s.uploads[id]![number] = req.body
                return .init(status: 200, headers: ["ETag": "\"\(Self.etag(req.body))\""])
            case "POST" where q("uploadId") != nil:
                let id = q("uploadId")!
                s.operations.append("complete")
                guard let parts = s.uploads[id] else { return .xml(404, "<Error><Code>NoSuchUpload</Code></Error>") }
                let xml = String(decoding: req.body, as: UTF8.self)
                let listed = xml.matches(of: /<Part><PartNumber>(\d+)<\/PartNumber><ETag>([^<]+)<\/ETag><\/Part>/)
                var assembled = Data()
                for (i, match) in listed.enumerated() {
                    guard let n = Int(match.1), n == i + 1, let data = parts[n],
                          match.2 == "\"\(Self.etag(data))\"" else {
                        return .xml(400, "<Error><Code>InvalidPart</Code></Error>")
                    }
                    assembled.append(data)
                }
                guard listed.count == parts.count else { return .xml(400, "<Error><Code>InvalidPart</Code></Error>") }
                s.objects[key] = assembled
                s.uploads[id] = nil
                s.completed.append(id)
                return .xml(200, "<CompleteMultipartUploadResult><Key>\(key)</Key></CompleteMultipartUploadResult>")
            case "DELETE" where q("uploadId") != nil:
                let id = q("uploadId")!
                s.operations.append("abort")
                s.uploads[id] = nil
                s.aborted.append(id)
                return .init(status: 204)
            case "PUT":
                s.operations.append("put")
                let hash = req.headers["x-amz-content-sha256"]
                guard hash == SigV4Signer.unsignedPayload || hash == SigV4Signer.sha256Hex(req.body) else {
                    return .xml(400, "<Error><Code>XAmzContentSHA256Mismatch</Code></Error>")
                }
                s.objects[key] = req.body
                s.contentTypes[key] = req.headers["content-type"]
                return .init(status: 200, headers: ["ETag": "\"\(Self.etag(req.body))\""])
            case "GET":
                guard let data = s.objects[key] else { return .xml(404, "<Error><Code>NoSuchKey</Code></Error>") }
                return .init(status: 200, headers: ["Content-Type": s.contentTypes[key] ?? "application/octet-stream"], body: data)
            case "DELETE":
                s.operations.append("delete")
                s.deleted.append(key)
                guard s.objects.removeValue(forKey: key) != nil else {
                    return .xml(404, "<Error><Code>NoSuchKey</Code></Error>")
                }
                return .init(status: 204)
            default:
                return .xml(405, "<Error><Code>MethodNotAllowed</Code></Error>")
            }
        }
    }

    static func etag(_ data: Data) -> String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Recomputes the signature from what actually arrived on the wire. Returns a problem description or nil.
    private func verifySignature(_ req: PublishMockHTTPServer.Request) -> String? {
        let signer = SigV4Signer(accessKeyID: accessKeyID, secretAccessKey: secret, region: region)
        let queryItems = req.queryItems
        if let presigned = queryItems.first(where: { $0.name == "X-Amz-Signature" })?.value {
            let query = queryItems.filter { $0.name != "X-Amz-Signature" }
            guard let dateText = query.first(where: { $0.name == "X-Amz-Date" })?.value,
                  let date = Self.amzDateFormatter.date(from: dateText) else { return "missing X-Amz-Date" }
            guard query.first(where: { $0.name == "X-Amz-Credential" })?.value
                    == "\(accessKeyID)/\(signer.credentialScope(date))" else { return "bad credential" }
            let (canonical, _) = SigV4Signer.canonicalRequest(method: req.method, encodedPath: req.rawPath, query: query,
                                                              headers: [("host", req.headers["host"] ?? "")],
                                                              payloadHash: SigV4Signer.unsignedPayload)
            let expected = signer.signature(stringToSign: signer.stringToSign(canonicalRequest: canonical, date: date), date: date)
            return expected == presigned ? nil : "presigned signature mismatch"
        }
        guard let auth = req.headers["authorization"],
              let signed = auth.firstMatch(of: /SignedHeaders=([^,]+)/)?.1,
              let signature = auth.firstMatch(of: /Signature=([0-9a-f]{64})/)?.1,
              let dateText = req.headers["x-amz-date"], let date = Self.amzDateFormatter.date(from: dateText),
              let payloadHash = req.headers["x-amz-content-sha256"] else { return "missing auth headers" }
        guard auth.hasPrefix("AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(signer.credentialScope(date)),") else {
            return "bad credential scope"
        }
        let names = signed.split(separator: ";").map(String.init)
        guard names.contains("host"), names.contains("x-amz-date"), names.contains("x-amz-content-sha256") else {
            return "required headers unsigned"
        }
        let headers = names.map { ($0, req.headers[$0] ?? "") }
        let (canonical, _) = SigV4Signer.canonicalRequest(method: req.method, encodedPath: req.rawPath, query: queryItems,
                                                          headers: headers, payloadHash: payloadHash)
        let expected = signer.signature(stringToSign: signer.stringToSign(canonicalRequest: canonical, date: date), date: date)
        return expected == String(signature) ? nil : "signature mismatch"
    }
}

/// Collects fractions reported through progress callbacks.
final class PublishProgressLog: Sendable {
    private let values = Mutex<[Double]>([])
    var all: [Double] { values.withLock { $0 } }
    var callback: @Sendable (Double) -> Void { { [self] v in values.withLock { $0.append(v) } } }
}

func publishTestSession() -> URLSession { URLSession(configuration: .ephemeral) }

func publishTempFile(bytes: Int, ext: String = "mp4", seed: UInt64 = 42) throws -> URL {
    var generator = PublishTestRNG(seed: seed)
    var data = Data(count: bytes)
    data.withUnsafeMutableBytes { raw in
        for i in 0..<bytes { raw[i] = UInt8(truncatingIfNeeded: generator.next()) }
    }
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("clipper-publish-\(UUID().uuidString).\(ext)")
    try data.write(to: url)
    return url
}

struct PublishTestRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Tests

/// 2013-05-24T00:00:00Z — the timestamp used by every AWS documentation example.
private let awsExampleDate = Date(timeIntervalSince1970: 1_369_353_600)
private let awsExampleSigner = SigV4Signer(accessKeyID: "AKIAIOSFODNN7EXAMPLE",
                                           secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
                                           region: "us-east-1")

@Suite("SigV4 + S3")
struct S3Tests {
    // Vectors from https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html

    @Test func amzDateFormatting() {
        #expect(SigV4Signer.amzDate(awsExampleDate) == "20130524T000000Z")
        #expect(SigV4Signer.dateStamp(awsExampleDate) == "20130524")
        #expect(awsExampleSigner.credentialScope(awsExampleDate) == "20130524/us-east-1/s3/aws4_request")
    }

    @Test func awsVectorGetObjectWithRange() {
        let headers = [("Host", "examplebucket.s3.amazonaws.com"), ("Range", "bytes=0-9"),
                       ("x-amz-content-sha256", SigV4Signer.emptyPayloadHash), ("x-amz-date", "20130524T000000Z")]
        let (canonical, signed) = SigV4Signer.canonicalRequest(method: "GET", encodedPath: "/test.txt", query: [],
                                                               headers: headers, payloadHash: SigV4Signer.emptyPayloadHash)
        #expect(canonical == """
            GET
            /test.txt

            host:examplebucket.s3.amazonaws.com
            range:bytes=0-9
            x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
            x-amz-date:20130524T000000Z

            host;range;x-amz-content-sha256;x-amz-date
            e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
            """)
        #expect(signed == "host;range;x-amz-content-sha256;x-amz-date")
        let sts = awsExampleSigner.stringToSign(canonicalRequest: canonical, date: awsExampleDate)
        #expect(sts == """
            AWS4-HMAC-SHA256
            20130524T000000Z
            20130524/us-east-1/s3/aws4_request
            7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972
            """)
        #expect(awsExampleSigner.signature(stringToSign: sts, date: awsExampleDate)
                == "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
        #expect(awsExampleSigner.authorization(method: "GET", encodedPath: "/test.txt", query: [], headers: headers,
                                               payloadHash: SigV4Signer.emptyPayloadHash, date: awsExampleDate)
                == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,SignedHeaders=host;range;x-amz-content-sha256;x-amz-date,Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    @Test func awsVectorPutObjectWithSpecialCharacterKey() {
        let payloadHash = SigV4Signer.sha256Hex("Welcome to Amazon S3.")
        #expect(payloadHash == "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072")
        let path = "/" + SigV4Signer.uriEncode("test$file.text", encodeSlash: false)
        #expect(path == "/test%24file.text")
        let headers = [("Date", "Fri, 24 May 2013 00:00:00 GMT"), ("Host", "examplebucket.s3.amazonaws.com"),
                       ("x-amz-content-sha256", payloadHash), ("x-amz-date", "20130524T000000Z"),
                       ("x-amz-storage-class", "REDUCED_REDUNDANCY")]
        let (canonical, _) = SigV4Signer.canonicalRequest(method: "PUT", encodedPath: path, query: [], headers: headers,
                                                          payloadHash: payloadHash)
        let sts = awsExampleSigner.stringToSign(canonicalRequest: canonical, date: awsExampleDate)
        #expect(sts.hasSuffix("9e0e90d9c76de8fa5b200d8c849cd5b8dc7a3be3951ddb7f6a76b4158342019d"))
        #expect(awsExampleSigner.signature(stringToSign: sts, date: awsExampleDate)
                == "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd")
    }

    @Test func awsVectorsWithQueryStrings() {
        let headers = [("Host", "examplebucket.s3.amazonaws.com"),
                       ("x-amz-content-sha256", SigV4Signer.emptyPayloadHash), ("x-amz-date", "20130524T000000Z")]
        // GET ?lifecycle → "lifecycle=" in the canonical query.
        let (lifecycle, _) = SigV4Signer.canonicalRequest(method: "GET", encodedPath: "/", query: [("lifecycle", "")],
                                                          headers: headers, payloadHash: SigV4Signer.emptyPayloadHash)
        #expect(lifecycle.split(separator: "\n", omittingEmptySubsequences: false)[2] == "lifecycle=")
        let lifecycleSTS = awsExampleSigner.stringToSign(canonicalRequest: lifecycle, date: awsExampleDate)
        #expect(lifecycleSTS.hasSuffix("9766c798316ff2757b517bc739a67f6213b4ab36dd5da2f94eaebf79c77395ca"))
        #expect(awsExampleSigner.signature(stringToSign: lifecycleSTS, date: awsExampleDate)
                == "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543")
        // GET ?max-keys=2&prefix=J (given out of order to exercise sorting).
        let (list, _) = SigV4Signer.canonicalRequest(method: "GET", encodedPath: "/", query: [("prefix", "J"), ("max-keys", "2")],
                                                     headers: headers, payloadHash: SigV4Signer.emptyPayloadHash)
        let listSTS = awsExampleSigner.stringToSign(canonicalRequest: list, date: awsExampleDate)
        #expect(listSTS.hasSuffix("df57d21db20da04d7fa30298dd4488ba3a2b47ca3a489c74750e0f1e7df1b9b7"))
        #expect(awsExampleSigner.signature(stringToSign: listSTS, date: awsExampleDate)
                == "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7")
    }

    // Vector from https://docs.aws.amazon.com/AmazonS3/latest/API/sigv4-query-string-auth.html

    @Test func awsVectorPresignedURL() throws {
        let query = awsExampleSigner.presignQuery(date: awsExampleDate, expires: 86400)
        let (canonical, _) = SigV4Signer.canonicalRequest(method: "GET", encodedPath: "/test.txt", query: query,
                                                          headers: [("host", "examplebucket.s3.amazonaws.com")],
                                                          payloadHash: SigV4Signer.unsignedPayload)
        #expect(canonical == """
            GET
            /test.txt
            X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host
            host:examplebucket.s3.amazonaws.com

            host
            UNSIGNED-PAYLOAD
            """)
        let sts = awsExampleSigner.stringToSign(canonicalRequest: canonical, date: awsExampleDate)
        #expect(sts == """
            AWS4-HMAC-SHA256
            20130524T000000Z
            20130524/us-east-1/s3/aws4_request
            3bfa292879f6447bbcda7001decf97f4a54dc650c8942174ae0a9121cf58ad04
            """)
        #expect(awsExampleSigner.signature(stringToSign: sts, date: awsExampleDate)
                == "aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404")

        // Through the client: virtual-hosted style on the AWS endpoint reproduces the documented URL byte for byte.
        let client = try S3Client(config: S3Config(endpoint: URL(string: "https://s3.amazonaws.com")!, region: "us-east-1",
                                                   bucket: "examplebucket", accessKeyID: "AKIAIOSFODNN7EXAMPLE",
                                                   secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", pathStyle: false),
                                  now: { awsExampleDate })
        let url = try client.presignedGetURL(key: "test.txt", expires: .seconds(86400))
        #expect(url.absoluteString == "https://examplebucket.s3.amazonaws.com/test.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404")
    }

    @Test func presignedURLFormatForR2AndExpiryLimits() throws {
        let client = try S3Client(config: S3Config(endpoint: URL(string: "https://acct123.r2.cloudflarestorage.com")!,
                                                   region: "auto", bucket: "my-bucket", accessKeyID: "AK",
                                                   secretAccessKey: "SK", pathStyle: true),
                                  now: { awsExampleDate })
        let url = try client.presignedGetURL(key: "clipper-tmp/a b/ré.mp4")
        let s = url.absoluteString
        #expect(s.hasPrefix("https://acct123.r2.cloudflarestorage.com/my-bucket/clipper-tmp/a%20b/r%C3%A9.mp4?"))
        #expect(s.contains("X-Amz-Credential=AK%2F20130524%2Fauto%2Fs3%2Faws4_request"))
        #expect(s.contains("X-Amz-Expires=3600&X-Amz-SignedHeaders=host&X-Amz-Signature="))
        #expect(s.firstMatch(of: /X-Amz-Signature=[0-9a-f]{64}$/) != nil)
        #expect(throws: S3Error.invalidExpiry(0)) { try client.presignedGetURL(key: "k", expires: .zero) }
        #expect(throws: S3Error.invalidExpiry(604_801)) { try client.presignedGetURL(key: "k", expires: .seconds(604_801)) }
        _ = try client.presignedGetURL(key: "k", expires: .seconds(604_800))
        #expect(!String(describing: client.config).contains("SK"))
    }

    @Test func uriEncoding() {
        #expect(SigV4Signer.uriEncode("a b/c~d-_.e") == "a%20b%2Fc~d-_.e")
        #expect(SigV4Signer.uriEncode("a b/c", encodeSlash: false) == "a%20b/c")
        #expect(SigV4Signer.uriEncode("é+=&") == "%C3%A9%2B%3D%26")
    }

    @Test func invalidConfigRejected() {
        #expect(throws: S3Error.self) {
            try S3Client(config: S3Config(endpoint: URL(string: "ftp://x")!, bucket: "b", accessKeyID: "a", secretAccessKey: "s"))
        }
        #expect(throws: S3Error.self) {
            try S3Client(config: S3Config(endpoint: URL(string: "https://x.com")!, bucket: "b", accessKeyID: "", secretAccessKey: "s"))
        }
    }

    @Test func partSizeStaysWithinPartLimit() throws {
        let client = try S3Client(config: S3Config(endpoint: URL(string: "https://x.com")!, bucket: "b",
                                                   accessKeyID: "a", secretAccessKey: "s"))
        #expect(client.effectivePartSize(for: 500 * 1024 * 1024) == 16 * 1024 * 1024)
        let huge: Int64 = 400 * 1024 * 1024 * 1024
        let part = client.effectivePartSize(for: huge)
        #expect((huge + part - 1) / part <= 10_000)
    }

    // MARK: Against the mock bucket

    private func makeServer(_ bucket: MockS3Bucket) async throws -> PublishMockHTTPServer {
        try await PublishMockHTTPServer { req in bucket.handle(req) ?? .init(status: 404) }
    }

    private func smallPartOptions() -> S3Client.Options {
        S3Client.Options(multipartThreshold: 64 * 1024, partSize: 20 * 1024, maxAttempts: 3, retryDelay: .milliseconds(10))
    }

    @Test func singlePutPresignedGetAndDelete() async throws {
        let bucket = MockS3Bucket()
        let server = try await makeServer(bucket)
        let client = try S3Client(config: bucket.config(server), options: smallPartOptions(), session: publishTestSession())
        let file = try publishTempFile(bytes: 50_000)
        defer { try? FileManager.default.removeItem(at: file) }
        let progress = PublishProgressLog()

        try await client.putObject(file: file, key: "tmp/my clip.mp4", contentType: "video/mp4", progress: progress.callback)
        let snap = bucket.snapshot
        #expect(snap.signatureFailures.isEmpty)
        #expect(snap.operations == ["put"])
        #expect(snap.objects["tmp/my clip.mp4"] == (try Data(contentsOf: file)))
        #expect(snap.contentTypes["tmp/my clip.mp4"] == "video/mp4")
        #expect(progress.all.first == 0 && progress.all.last == 1)

        // Presigned GET is fetched without any headers; the mock re-verifies the query signature.
        let url = try client.presignedGetURL(key: "tmp/my clip.mp4", expires: .seconds(60))
        let (data, response) = try await publishTestSession().data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(data == (try Data(contentsOf: file)))

        try await client.deleteObject(key: "tmp/my clip.mp4")
        #expect(bucket.objects.isEmpty)
        try await client.deleteObject(key: "tmp/missing.mp4")   // 404 is fine
        #expect(bucket.snapshot.signatureFailures.isEmpty)
    }

    @Test func multipartUploadReassemblesExactly() async throws {
        let bucket = MockS3Bucket()
        let server = try await makeServer(bucket)
        let client = try S3Client(config: bucket.config(server), options: smallPartOptions(), session: publishTestSession())
        let size = 150 * 1024 + 7
        let file = try publishTempFile(bytes: size, seed: 7)
        defer { try? FileManager.default.removeItem(at: file) }
        let progress = PublishProgressLog()

        try await client.putObject(file: file, key: "big.mp4", contentType: "video/mp4", progress: progress.callback)
        let snap = bucket.snapshot
        #expect(snap.signatureFailures.isEmpty)
        #expect(snap.operations == ["create"] + (1...8).map { "part\($0)" } + ["complete"])
        #expect(snap.objects["big.mp4"] == (try Data(contentsOf: file)))
        #expect(snap.contentTypes["big.mp4"] == "video/mp4")
        #expect(snap.completed.count == 1 && snap.aborted.isEmpty && snap.uploads.isEmpty)
        #expect(progress.all == progress.all.sorted())
        #expect(progress.all.last == 1)
    }

    @Test func multipartRetriesTransientPartFailure() async throws {
        let bucket = MockS3Bucket()
        bucket.state.withLock { $0.failPart = (2, 503, 1) }
        let server = try await makeServer(bucket)
        let client = try S3Client(config: bucket.config(server), options: smallPartOptions(), session: publishTestSession())
        let file = try publishTempFile(bytes: 100 * 1024, seed: 9)
        defer { try? FileManager.default.removeItem(at: file) }

        try await client.putObject(file: file, key: "retry.mp4", contentType: "video/mp4")
        let snap = bucket.snapshot
        #expect(snap.operations.filter { $0 == "part2" }.count == 2)
        #expect(snap.objects["retry.mp4"] == (try Data(contentsOf: file)))
    }

    @Test func multipartAbortsOnFailure() async throws {
        let bucket = MockS3Bucket()
        bucket.state.withLock { $0.failPart = (3, 403, 100) }
        let server = try await makeServer(bucket)
        let client = try S3Client(config: bucket.config(server), options: smallPartOptions(), session: publishTestSession())
        let file = try publishTempFile(bytes: 120 * 1024, seed: 11)
        defer { try? FileManager.default.removeItem(at: file) }

        await #expect {
            try await client.putObject(file: file, key: "fail.mp4", contentType: "video/mp4")
        } throws: { error in
            guard case let .http(op, status, code, _) = error as? S3Error else { return false }
            return op == "UploadPart" && status == 403 && code == "InjectedFailure"
        }
        let snap = bucket.snapshot
        #expect(snap.operations == ["create", "part1", "part2", "part3", "abort"])
        #expect(snap.aborted == ["upload-1"])
        #expect(snap.objects.isEmpty && snap.uploads.isEmpty)
    }
}
