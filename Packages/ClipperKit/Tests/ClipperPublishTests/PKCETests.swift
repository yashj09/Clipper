@testable import ClipperPublish
import Foundation
import Testing

@Suite struct PKCETests {
    /// RFC 7636 Appendix B.
    static let rfcVerifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"

    @Test func s256MatchesRFC7636AppendixB() {
        #expect(PKCE.challenge(for: Self.rfcVerifier, method: .s256) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func tiktokHexVariantIsLowercaseHexSHA256() {
        // SHA256("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") in hex (CryptoJS.SHA256(v).toString(CryptoJS.enc.Hex)).
        #expect(PKCE.challenge(for: Self.rfcVerifier, method: .tiktokHexS256)
                == "13d31e961a1ad8ec2f16b10c4c982e0876a878ad6df144566ee1894acb70f9c3")
        let pkce = PKCE(verifier: Self.rfcVerifier, method: .tiktokHexS256)
        #expect(pkce.challengeMethodParameter == "S256")
    }

    @Test func generatedVerifiersAreValidAndUnique() {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let first = PKCE.generate(method: .s256)
        let second = PKCE.generate(method: .s256)
        #expect(first.verifier != second.verifier)
        for pkce in [first, second] {
            #expect((43...128).contains(pkce.verifier.count))
            #expect(pkce.verifier.unicodeScalars.allSatisfy(allowed.contains))
            #expect(!pkce.challenge.contains("=") && !pkce.challenge.contains("+") && !pkce.challenge.contains("/"))
            #expect(pkce.challenge.count == 43)
        }
    }
}
