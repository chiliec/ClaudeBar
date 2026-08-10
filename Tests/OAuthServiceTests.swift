import Foundation
import Testing
@testable import ClaudeBarUI

@Suite
struct OAuthServiceTests {
    // RFC 7636 appendix B test vector.
    @Test func codeChallengeMatchesRFCVector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(OAuthService.codeChallenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func randomVerifierIsURLSafeAndLongEnough() {
        let verifier = OAuthService.randomURLSafeString()
        #expect(verifier.count >= 43)
        #expect(verifier.count <= 128)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        #expect(verifier.unicodeScalars.allSatisfy { allowed.contains($0) })
        #expect(verifier != OAuthService.randomURLSafeString())
    }

    @Test func authorizeURLCarriesEveryPKCEParameter() throws {
        let url = try OAuthService.authorizeURL(codeChallenge: "chal-123", state: "state-abc")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        var params: [String: String] = [:]
        for item in components.queryItems ?? [] { params[item.name] = item.value }

        #expect(components.host == "claude.ai")
        #expect(components.path == "/oauth/authorize")
        #expect(params["response_type"] == "code")
        #expect(params["client_id"] == OAuthService.clientID)
        #expect(params["redirect_uri"] == "http://localhost:54545/callback")
        #expect(params["code_challenge"] == "chal-123")
        #expect(params["code_challenge_method"] == "S256")
        #expect(params["state"] == "state-abc")
        #expect(params["scope"] == OAuthService.scope)
    }
}
