import CryptoKit
import Foundation

/// Connection settings for an S3-compatible bucket ("bring your own keys"). Stored as JSON in the credential store
/// under `S3Config.credentialKey` ("storage.s3").
///
/// Examples:
/// - Cloudflare R2: endpoint `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`, region `auto`, pathStyle true.
/// - AWS S3: endpoint `https://s3.<region>.amazonaws.com`, region e.g. `eu-west-1`, pathStyle false.
/// - MinIO: endpoint `http://127.0.0.1:9000`, region `us-east-1`, pathStyle true.
/// - Backblaze B2: endpoint `https://s3.<region>.backblazeb2.com`, region e.g. `us-west-004`, pathStyle true.
public struct S3Config: Codable, Sendable, Equatable, CustomStringConvertible {
    /// Credential-store key holding this config as JSON.
    public static let credentialKey = "storage.s3"

    public var endpoint: URL
    public var region: String
    public var bucket: String
    public var accessKeyID: String
    public var secretAccessKey: String
    /// `https://endpoint/bucket/key` (true) or `https://bucket.endpoint/key` (false).
    public var pathStyle: Bool

    public init(endpoint: URL, region: String = "auto", bucket: String, accessKeyID: String, secretAccessKey: String,
                pathStyle: Bool = true) {
        self.endpoint = endpoint; self.region = region; self.bucket = bucket
        self.accessKeyID = accessKeyID; self.secretAccessKey = secretAccessKey; self.pathStyle = pathStyle
    }

    /// Never prints the secret.
    public var description: String {
        "S3Config(endpoint: \(endpoint.absoluteString), region: \(region), bucket: \(bucket), accessKeyID: \(accessKeyID), pathStyle: \(pathStyle))"
    }
}

public enum S3Error: Error, LocalizedError, Equatable {
    case invalidConfig(String)
    case fileNotReadable(URL)
    case http(operation: String, status: Int, code: String?, message: String?)
    case malformedResponse(String)
    case invalidExpiry(Int)

    public var errorDescription: String? {
        switch self {
        case let .invalidConfig(why): "Storage configuration is invalid: \(why)"
        case let .fileNotReadable(url): "Cannot read \(url.path)"
        case let .http(op, status, code, message):
            "Storage \(op) failed (HTTP \(status)\(code.map { ", \($0)" } ?? ""))\(message.map { ": \($0)" } ?? "")"
        case let .malformedResponse(why): "Unexpected storage response: \(why)"
        case let .invalidExpiry(s): "Presigned URL expiry must be 1…\(SigV4Signer.maxPresignExpiry) seconds (got \(s))"
        }
    }
}

/// Minimal S3 client: single and multipart PUT, presigned GET, DELETE. Requests are signed with SigV4; single PUTs
/// and parts carry their real SHA-256 payload hash.
public struct S3Client: Sendable {
    public struct Options: Sendable {
        /// Files larger than this use multipart upload.
        public var multipartThreshold: Int64
        /// Preferred part size; grown automatically so an upload never exceeds 10,000 parts. All parts except the
        /// last have exactly this size (R2 requires equal part sizes; S3/R2 require ≥ 5 MiB except the last part).
        public var partSize: Int64
        /// Attempts per request for transport errors and HTTP 5xx/429.
        public var maxAttempts: Int
        public var retryDelay: Duration

        public init(multipartThreshold: Int64 = 100 * 1024 * 1024, partSize: Int64 = 16 * 1024 * 1024,
                    maxAttempts: Int = 3, retryDelay: Duration = .seconds(1)) {
            self.multipartThreshold = multipartThreshold; self.partSize = partSize
            self.maxAttempts = max(1, maxAttempts); self.retryDelay = retryDelay
        }
    }

    public static let maxParts: Int64 = 10_000

    public let config: S3Config
    public let options: Options
    let session: URLSession
    let now: @Sendable () -> Date
    let signer: SigV4Signer

    public init(config: S3Config, options: Options = Options(), session: URLSession = URLSession(configuration: .ephemeral),
                now: @escaping @Sendable () -> Date = { Date() }) throws {
        guard let scheme = config.endpoint.scheme?.lowercased(), scheme == "https" || scheme == "http",
              config.endpoint.host() != nil else {
            throw S3Error.invalidConfig("endpoint must be an http(s) URL, got \(config.endpoint.absoluteString)")
        }
        guard !config.bucket.isEmpty, !config.bucket.contains("/") else { throw S3Error.invalidConfig("bad bucket name") }
        guard !config.accessKeyID.isEmpty, !config.secretAccessKey.isEmpty else {
            throw S3Error.invalidConfig("access key id and secret access key are required")
        }
        self.config = config; self.options = options; self.session = session; self.now = now
        signer = SigV4Signer(accessKeyID: config.accessKeyID, secretAccessKey: config.secretAccessKey,
                             region: config.region.isEmpty ? "auto" : config.region)
    }

    // MARK: Addressing

    /// Host header value (authority including a non-default port).
    var hostHeader: String {
        let host = config.endpoint.host()!
        let base = config.pathStyle ? host : "\(config.bucket).\(host)"
        if let port = config.endpoint.port, !(port == 443 && scheme == "https"), !(port == 80 && scheme == "http") {
            return "\(base):\(port)"
        }
        return base
    }

    var scheme: String { config.endpoint.scheme!.lowercased() }

    /// URI-encoded path for an object key (each segment encoded once, as S3 expects).
    func encodedPath(key: String) -> String {
        let encodedKey = SigV4Signer.uriEncode(key, encodeSlash: false)
        return config.pathStyle ? "/\(SigV4Signer.uriEncode(config.bucket))/\(encodedKey)" : "/\(encodedKey)"
    }

    func url(path: String, query: [(name: String, value: String)]) -> URL {
        let q = query.isEmpty ? "" : "?" + SigV4Signer.canonicalQueryString(query)
        return URL(string: "\(scheme)://\(hostHeader)\(path)\(q)")!
    }

    // MARK: Public operations

    /// Uploads `file` to `key`. Uses a single PUT up to `multipartThreshold`, multipart above it (aborted on failure).
    /// `progress` receives the uploaded fraction 0…1.
    public func putObject(file: URL, key: String, contentType: String,
                          progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int64 else {
            throw S3Error.fileNotReadable(file)
        }
        progress?(0)
        if size > options.multipartThreshold {
            try await multipartUpload(file: file, size: size, key: key, contentType: contentType, progress: progress)
        } else {
            let hash = try Self.sha256Hex(file: file)
            let path = encodedPath(key: key)
            _ = try await send(operation: "PutObject", method: "PUT", path: path, query: [],
                               headers: [("content-type", contentType)], payloadHash: hash, body: .file(file))
        }
        progress?(1)
    }

    /// A time-limited GET URL for `key` (1 second … 7 days).
    public func presignedGetURL(key: String, expires: Duration = .seconds(3600)) throws -> URL {
        let seconds = Int(expires.components.seconds)
        guard (1...SigV4Signer.maxPresignExpiry).contains(seconds) else { throw S3Error.invalidExpiry(seconds) }
        return signer.presignedURL(scheme: scheme, host: hostHeader, encodedPath: encodedPath(key: key),
                                   date: now(), expires: seconds)
    }

    /// Deletes `key`. Deleting a missing object succeeds (S3 semantics).
    public func deleteObject(key: String) async throws {
        _ = try await send(operation: "DeleteObject", method: "DELETE", path: encodedPath(key: key), query: [],
                           headers: [], payloadHash: SigV4Signer.emptyPayloadHash, body: .none, accept: [404])
    }

    // MARK: Multipart

    /// Part size used for a file of `size` bytes: the configured size, grown to keep ≤ 10,000 parts.
    public func effectivePartSize(for size: Int64) -> Int64 {
        max(options.partSize, (size + Self.maxParts - 1) / Self.maxParts, 1)
    }

    private func multipartUpload(file: URL, size: Int64, key: String, contentType: String,
                                 progress: (@Sendable (Double) -> Void)?) async throws {
        let path = encodedPath(key: key)
        let created = try await send(operation: "CreateMultipartUpload", method: "POST", path: path,
                                     query: [("uploads", "")], headers: [("content-type", contentType)],
                                     payloadHash: SigV4Signer.emptyPayloadHash, body: .none)
        guard let uploadID = Self.xmlValue("UploadId", in: created.body) else {
            throw S3Error.malformedResponse("CreateMultipartUpload returned no UploadId")
        }
        do {
            let partSize = effectivePartSize(for: size)
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var etags: [String] = []
            var offset: Int64 = 0
            var partNumber = 1
            while offset < size {
                try Task.checkCancellation()
                let length = Int(min(partSize, size - offset))
                try handle.seek(toOffset: UInt64(offset))
                guard let chunk = try handle.read(upToCount: length), chunk.count == length else {
                    throw S3Error.fileNotReadable(file)
                }
                let response = try await send(operation: "UploadPart", method: "PUT", path: path,
                                              query: [("partNumber", String(partNumber)), ("uploadId", uploadID)],
                                              headers: [], payloadHash: SigV4Signer.sha256Hex(chunk), body: .data(chunk))
                guard let etag = response.http.value(forHTTPHeaderField: "ETag"), !etag.isEmpty else {
                    throw S3Error.malformedResponse("UploadPart \(partNumber) returned no ETag")
                }
                etags.append(etag)
                offset += Int64(length)
                partNumber += 1
                progress?(Double(offset) / Double(size) * 0.99)
            }
            let xml = Self.completeMultipartXML(etags: etags)
            let completeBody = Data(xml.utf8)
            let completed = try await send(operation: "CompleteMultipartUpload", method: "POST", path: path,
                                           query: [("uploadId", uploadID)], headers: [("content-type", "application/xml")],
                                           payloadHash: SigV4Signer.sha256Hex(completeBody), body: .data(completeBody))
            // S3 can report a failed completion with HTTP 200 and an <Error> body.
            if Self.xmlValue("Code", in: completed.body) != nil, completed.body.range(of: Data("<Error>".utf8)) != nil {
                throw S3Error.http(operation: "CompleteMultipartUpload", status: completed.http.statusCode,
                                   code: Self.xmlValue("Code", in: completed.body),
                                   message: Self.xmlValue("Message", in: completed.body))
            }
        } catch {
            // Best effort; runs even if the surrounding task was cancelled.
            let abort = Task { [self] in
                try? await send(operation: "AbortMultipartUpload", method: "DELETE", path: path,
                                query: [("uploadId", uploadID)], headers: [],
                                payloadHash: SigV4Signer.emptyPayloadHash, body: .none, accept: [404])
            }
            _ = await abort.value
            throw error
        }
    }

    static func completeMultipartXML(etags: [String]) -> String {
        let parts = etags.enumerated().map { i, etag in
            "<Part><PartNumber>\(i + 1)</PartNumber><ETag>\(xmlEscape(etag))</ETag></Part>"
        }.joined()
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<CompleteMultipartUpload xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">\(parts)</CompleteMultipartUpload>"
    }

    // MARK: Transport

    enum Body: Sendable {
        case none
        case data(Data)
        case file(URL)
    }

    struct Response: Sendable {
        var http: HTTPURLResponse
        var body: Data
    }

    /// Signs and sends one request, retrying transport errors and 5xx/429. Statuses in `accept` count as success.
    @discardableResult
    func send(operation: String, method: String, path: String, query: [(name: String, value: String)],
              headers extra: [(name: String, value: String)], payloadHash: String, body: Body,
              accept: Set<Int> = []) async throws -> Response {
        var attempt = 0
        while true {
            attempt += 1
            let date = now()
            var headers: [(name: String, value: String)] = [
                ("host", hostHeader), ("x-amz-content-sha256", payloadHash), ("x-amz-date", SigV4Signer.amzDate(date)),
            ] + extra
            let auth = signer.authorization(method: method, encodedPath: path, query: query, headers: headers,
                                            payloadHash: payloadHash, date: date)
            headers.removeFirst()   // URLSession sets Host itself (same value)
            var request = URLRequest(url: url(path: path, query: query))
            request.httpMethod = method
            request.timeoutInterval = 300
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            request.setValue(auth, forHTTPHeaderField: "Authorization")
            do {
                let (data, response): (Data, URLResponse)
                switch body {
                case .none: (data, response) = try await session.data(for: request)
                case let .data(payload): (data, response) = try await session.upload(for: request, from: payload)
                case let .file(url): (data, response) = try await session.upload(for: request, fromFile: url)
                }
                guard let http = response as? HTTPURLResponse else { throw S3Error.malformedResponse("not HTTP") }
                if (200..<300).contains(http.statusCode) || accept.contains(http.statusCode) {
                    return Response(http: http, body: data)
                }
                let failure = S3Error.http(operation: operation, status: http.statusCode,
                                           code: Self.xmlValue("Code", in: data), message: Self.xmlValue("Message", in: data))
                guard http.statusCode >= 500 || http.statusCode == 429, attempt < options.maxAttempts else { throw failure }
            } catch let error as URLError where error.code != .cancelled && attempt < options.maxAttempts {
                _ = error
            }
            try await Task.sleep(for: options.retryDelay * attempt)
        }
    }

    // MARK: Helpers

    static func sha256Hex(file: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { throw S3Error.fileNotReadable(file) }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
        return SigV4Signer.hex(hasher.finalize())
    }

    /// First `<name>…</name>` text in an XML body (S3 responses are small and flat enough for this).
    static func xmlValue(_ name: String, in data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
        return xmlUnescape(String(text[open.upperBound..<close.lowerBound]))
    }

    /// Escapes element text. Quotes stay literal: ETags are sent as `"…"` exactly like the AWS examples.
    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func xmlUnescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }
}
