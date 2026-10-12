import CryptoKit
import Foundation

/// AWS Signature Version 4 for S3-compatible services (AWS S3, Cloudflare R2, MinIO, Backblaze B2's S3 API).
///
/// Implements the two forms S3 uses:
/// - the `Authorization` header ("Signature Calculations for the Authorization Header: Transferring Payload in a
///   Single Chunk"), and
/// - query-string auth / presigned URLs ("Authenticating Requests: Using Query Parameters").
///
/// Verified against the worked examples in the AWS docs (see `S3Tests`):
/// https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html
/// https://docs.aws.amazon.com/AmazonS3/latest/API/sigv4-query-string-auth.html
public struct SigV4Signer: Sendable {
    public static let algorithm = "AWS4-HMAC-SHA256"
    /// Hash of the empty payload.
    public static let emptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    public static let unsignedPayload = "UNSIGNED-PAYLOAD"
    /// Longest validity S3 (and R2) accept for a presigned URL: 7 days.
    public static let maxPresignExpiry = 604_800

    public var accessKeyID: String
    public var secretAccessKey: String
    public var region: String
    public var service: String

    public init(accessKeyID: String, secretAccessKey: String, region: String, service: String = "s3") {
        self.accessKeyID = accessKeyID; self.secretAccessKey = secretAccessKey; self.region = region; self.service = service
    }

    // MARK: Building blocks

    /// `20130524T000000Z`
    public static func amzDate(_ date: Date) -> String {
        let c = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    /// `20130524`
    public static func dateStamp(_ date: Date) -> String { String(amzDate(date).prefix(8)) }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// RFC 3986 encoding as SigV4 defines it: everything except `A-Z a-z 0-9 - _ . ~` is percent-encoded (uppercase
    /// hex, UTF-8). `/` is kept only when `encodeSlash` is false (object key paths).
    public static func uriEncode(_ string: String, encodeSlash: Bool = true) -> String {
        var out = ""
        out.reserveCapacity(string.utf8.count)
        for byte in string.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."),
                 UInt8(ascii: "~"):
                out.unicodeScalars.append(Unicode.Scalar(byte))
            case UInt8(ascii: "/") where !encodeSlash:
                out.append("/")
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    /// Query parameters (raw, unencoded) → canonical query string: encoded names and values, sorted by name then value.
    public static func canonicalQueryString(_ query: [(name: String, value: String)]) -> String {
        let encoded: [(String, String)] = query.map { (uriEncode($0.name), uriEncode($0.value)) }
        let sorted = encoded.sorted { (a: (String, String), b: (String, String)) -> Bool in
            a.0 == b.0 ? a.1 < b.1 : a.0 < b.0
        }
        return sorted.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }

    public static func sha256Hex(_ data: some DataProtocol) -> String { hex(SHA256.hash(data: data)) }
    public static func sha256Hex(_ string: String) -> String { sha256Hex(Data(string.utf8)) }

    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Canonical request. `encodedPath` is already URI-encoded (S3: each key segment encoded once, `/` kept).
    /// Header names are lowercased, values trimmed with inner whitespace runs collapsed, sorted by name.
    public static func canonicalRequest(method: String, encodedPath: String, query: [(name: String, value: String)],
                                        headers: [(name: String, value: String)], payloadHash: String)
        -> (request: String, signedHeaders: String) {
        let canonicalHeaders = headers
            .map { (name: $0.name.lowercased(), value: collapseWhitespace($0.value)) }
            .sorted { $0.name < $1.name }
        let signedHeaders = canonicalHeaders.map(\.name).joined(separator: ";")
        let request = [
            method,
            encodedPath.isEmpty ? "/" : encodedPath,
            canonicalQueryString(query),
            canonicalHeaders.map { "\($0.name):\($0.value)\n" }.joined(),
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")
        return (request, signedHeaders)
    }

    private static func collapseWhitespace(_ value: String) -> String {
        value.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    public func credentialScope(_ date: Date) -> String {
        "\(Self.dateStamp(date))/\(region)/\(service)/aws4_request"
    }

    public func stringToSign(canonicalRequest: String, date: Date) -> String {
        [Self.algorithm, Self.amzDate(date), credentialScope(date), Self.sha256Hex(canonicalRequest)]
            .joined(separator: "\n")
    }

    public func signingKey(_ date: Date) -> SymmetricKey {
        func hmac(_ key: SymmetricKey, _ message: String) -> SymmetricKey {
            SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)))
        }
        let kDate = hmac(SymmetricKey(data: Data("AWS4\(secretAccessKey)".utf8)), Self.dateStamp(date))
        return hmac(hmac(hmac(kDate, region), service), "aws4_request")
    }

    public func signature(stringToSign: String, date: Date) -> String {
        Self.hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: signingKey(date)))
    }

    // MARK: High level

    /// `Authorization` header value for a request whose headers (including `host`, `x-amz-date` and
    /// `x-amz-content-sha256`) are all signed.
    public func authorization(method: String, encodedPath: String, query: [(name: String, value: String)],
                              headers: [(name: String, value: String)], payloadHash: String, date: Date) -> String {
        let (canonical, signed) = Self.canonicalRequest(method: method, encodedPath: encodedPath, query: query,
                                                         headers: headers, payloadHash: payloadHash)
        let sig = signature(stringToSign: stringToSign(canonicalRequest: canonical, date: date), date: date)
        return "\(Self.algorithm) Credential=\(accessKeyID)/\(credentialScope(date)),SignedHeaders=\(signed),Signature=\(sig)"
    }

    /// Query parameters of a presigned request (without the signature), in the order AWS documents them.
    public func presignQuery(date: Date, expires: Int, signedHeaders: String = "host",
                             extra: [(name: String, value: String)] = []) -> [(name: String, value: String)] {
        extra + [
            ("X-Amz-Algorithm", Self.algorithm),
            ("X-Amz-Credential", "\(accessKeyID)/\(credentialScope(date))"),
            ("X-Amz-Date", Self.amzDate(date)),
            ("X-Amz-Expires", String(expires)),
            ("X-Amz-SignedHeaders", signedHeaders),
        ]
    }

    /// Presigned URL (only `host` signed, payload `UNSIGNED-PAYLOAD`). `baseURL` is scheme + authority;
    /// `host` is the value of the Host header (authority, with a non-default port).
    public func presignedURL(method: String = "GET", scheme: String, host: String, encodedPath: String,
                             date: Date, expires: Int, extraQuery: [(name: String, value: String)] = []) -> URL {
        let query = presignQuery(date: date, expires: expires, extra: extraQuery)
        let (canonical, _) = Self.canonicalRequest(method: method, encodedPath: encodedPath, query: query,
                                                   headers: [("host", host)], payloadHash: Self.unsignedPayload)
        let sig = signature(stringToSign: stringToSign(canonicalRequest: canonical, date: date), date: date)
        let queryString = Self.canonicalQueryString(query) + "&X-Amz-Signature=\(sig)"
        return URL(string: "\(scheme)://\(host)\(encodedPath)?\(queryString)")!
    }
}
