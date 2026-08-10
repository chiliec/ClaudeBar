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
        let url = try OAuthService.authorizeURL(codeChallenge: "chal-123", state: "state-abc", port: 54545)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        var params: [String: String] = [:]
        for item in components.queryItems ?? [] { params[item.name] = item.value }

        #expect(components.host == "claude.com")
        #expect(components.path == "/cai/oauth/authorize")
        #expect(params["code"] == "true")
        #expect(params["response_type"] == "code")
        #expect(params["client_id"] == OAuthService.clientID)
        #expect(params["redirect_uri"] == "http://localhost:54545/callback")
        #expect(params["code_challenge"] == "chal-123")
        #expect(params["code_challenge_method"] == "S256")
        #expect(params["state"] == "state-abc")
        // Spaces travel as `+` (URLSearchParams form-encoding, matching the
        // CLI); URLComponents doesn't decode that, so undo it here.
        #expect(params["scope"]?.replacingOccurrences(of: "+", with: " ") == OAuthService.scope)
    }
}

@Suite
struct OAuthCallbackServerTests {
    /// Regression: the timeout used to deadlock in the task group's implicit
    /// await because `accept()`'s continuation ignored cancellation.
    @Test func timeoutThrowsInsteadOfHanging() async {
        await #expect(throws: OAuthError.timedOut) {
            _ = try await OAuthCallbackServer().waitForCallback(timeout: 0.2) { _ in }
        }
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

@Suite
struct OAuthTokenTests {
    @Test func parsesTokenResponse() throws {
        let json = """
        {
          "access_token": "sk-at-123",
          "refresh_token": "sk-rt-456",
          "expires_in": 3600,
          "token_type": "Bearer"
        }
        """.data(using: .utf8)!
        let now = Date(timeIntervalSince1970: 1_000_000)
        let creds = try OAuthService.parseTokenResponse(data: json, now: now)

        #expect(creds.accessToken == "sk-at-123")
        #expect(creds.refreshToken == "sk-rt-456")
        #expect(abs(creds.expiresAt.timeIntervalSince(now) - 3600) < 1)
    }

    @Test func keepsPreviousRefreshTokenWhenServerOmitsIt() throws {
        let json = """
        { "access_token": "sk-at-new", "expires_in": 3600 }
        """.data(using: .utf8)!
        let creds = try OAuthService.parseTokenResponse(data: json, previousRefreshToken: "sk-rt-old")

        #expect(creds.accessToken == "sk-at-new")
        #expect(creds.refreshToken == "sk-rt-old")
    }

    @Test func needsRefreshInsideFiveMinuteWindow() {
        let now = Date()
        let expiring = OAuthCredentials(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(120))
        let fresh = OAuthCredentials(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(3600))
        let expired = OAuthCredentials(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(-60))

        #expect(OAuthService.needsRefresh(expiring, now: now))
        #expect(!OAuthService.needsRefresh(fresh, now: now))
        #expect(OAuthService.needsRefresh(expired, now: now))
    }

    @Test func roundTripsThroughKeychain() throws {
        let keychain = KeychainService(serviceName: "com.claudebar.test")
        OAuthService.clear(from: keychain)
        let creds = OAuthCredentials(
            accessToken: "sk-at-123",
            refreshToken: "sk-rt-456",
            expiresAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try OAuthService.save(creds, to: keychain)

        #expect(try OAuthService.load(from: keychain) == creds)

        OAuthService.clear(from: keychain)
        #expect(try OAuthService.load(from: keychain) == nil)
    }
}
