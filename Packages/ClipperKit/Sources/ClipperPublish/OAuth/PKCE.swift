import CryptoKit
import Foundation
import Security

/// How the PKCE code challenge is derived from the verifier (RFC 7636 §4.2).
public enum PKCEMethod: String, Codable, Sendable {
    /// Standard S256: BASE64URL(SHA256(ascii(verifier))), no padding.
    case s256
    /// TikTok Login Kit for Desktop: lower-case hex of SHA256(verifier), still sent as `code_challenge_method=S256`.
    /// https://developers.tiktok.com/doc/login-kit-desktop : "You must use hex encoding of SHA256 to generate the code
    /// challenge from the code verifier" (`CryptoJS.SHA256(code_verifier).toString(CryptoJS.enc.Hex)`).
    case tiktokHexS256
}

public struct PKCE: Sendable, Equatable {
    public let verifier: String
    public let challenge: String
    public let method: PKCEMethod
    /// Value for `code_challenge_method`; both variants send "S256".
    public var challengeMethodParameter: String { "S256" }

    public init(verifier: String, method: PKCEMethod) {
        self.verifier = verifier
        self.method = method
        self.challenge = PKCE.challenge(for: verifier, method: method)
    }

    /// Fresh random verifier: 64 characters from the unreserved set (RFC 7636 allows 43–128).
    public static func generate(method: PKCEMethod) -> PKCE {
        PKCE(verifier: randomString(length: 64), method: method)
    }

    public static func challenge(for verifier: String, method: PKCEMethod) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        switch method {
        case .s256: return base64URL(Data(digest))
        case .tiktokHexS256: return digest.map { String(format: "%02x", $0) }.joined()
        }
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Random string over [A-Za-z0-9-._~] from SecRandomCopyBytes (rejection sampling, so no modulo bias).
    static func randomString(length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var result = ""
        result.reserveCapacity(length)
        while result.count < length {
            var bytes = [UInt8](repeating: 0, count: length)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
            for byte in bytes where Int(byte) < 256 - (256 % alphabet.count) && result.count < length {
                result.append(alphabet[Int(byte) % alphabet.count])
            }
        }
        return result
    }
}
