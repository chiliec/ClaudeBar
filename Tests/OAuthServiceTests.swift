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

@Suite
struct OAuthCallbackParsingTests {
    @Test func extractsCodeAndState() {
        let head = "GET /callback?code=abc123&state=xyz HTTP/1.1\r\nHost: localhost:54545\r\n\r\n"
        let params = OAuthCallbackServer.parseCallback(requestHead: head)
        #expect(params?["code"] == "abc123")
        #expect(params?["state"] == "xyz")
    }

    @Test func percentDecodesValues() {
        let head = "GET /callback?code=a%2Fb%2Bc&state=s%20t HTTP/1.1\r\n\r\n"
        let params = OAuthCallbackServer.parseCallback(requestHead: head)
        #expect(params?["code"] == "a/b+c")
        #expect(params?["state"] == "s t")
    }

    @Test func surfacesDenialParameters() {
        let head = "GET /callback?error=access_denied&state=xyz HTTP/1.1\r\n\r\n"
        let params = OAuthCallbackServer.parseCallback(requestHead: head)
        #expect(params?["error"] == "access_denied")
        #expect(params?["code"] == nil)
    }

    @Test func ignoresOtherPaths() {
        #expect(OAuthCallbackServer.parseCallback(requestHead: "GET /favicon.ico HTTP/1.1\r\n\r\n") == nil)
    }

    @Test func ignoresNonGETMethods() {
        #expect(OAuthCallbackServer.parseCallback(requestHead: "POST /callback?code=a HTTP/1.1\r\n\r\n") == nil)
    }

    @Test func ignoresGarbage() {
        #expect(OAuthCallbackServer.parseCallback(requestHead: "") == nil)
        #expect(OAuthCallbackServer.parseCallback(requestHead: "hello") == nil)
    }
}
