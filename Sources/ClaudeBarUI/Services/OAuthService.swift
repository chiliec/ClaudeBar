import AppKit
import CryptoKit
import Foundation

/// Failures specific to the browser sign-in flow. Distinct from `APIError`
/// (which owns data-endpoint failures) and `PlatformAuthError` (which owns the
/// platform.claude.com cookie).
public enum OAuthError: Error, Equatable {
    /// The loopback listener could not bind — usually port 54545 is already taken.
    case listenerFailed(String)
    case timedOut
    case stateMismatch
    /// The consent page came back with `error=<reason>` instead of a code.
    case denied(String)
    case tokenExchangeFailed(Int)

    public var displayMessage: String {
        switch self {
        case .listenerFailed: return String(localized: "oauthError.listenerFailed", bundle: .module)
        case .timedOut: return String(localized: "oauthError.timedOut", bundle: .module)
        case .stateMismatch: return String(localized: "oauthError.stateMismatch", bundle: .module)
        case .denied: return String(localized: "oauthError.denied", bundle: .module)
        case .tokenExchangeFailed(let code): return String(localized: "oauthError.tokenExchangeFailed \(code)", bundle: .module)
        }
    }
}

public enum OAuthService {
    /// Claude Code's public client ID. No third-party OAuth registration exists
    /// for claude.ai; see the spec's risk section.
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    public static let redirectURI = "http://localhost:54545/callback"
    /// Minimal scope set verified in task 0.
    public static let scope = "user:profile"
    static let authorizeEndpoint = "https://claude.ai/oauth/authorize"
    /// Verified in task 0 — console.anthropic.com 429s, claude.ai/api/oauth/token
    /// hits a Cloudflare bot challenge. api.anthropic.com is the real one.
    static let tokenEndpoint = "https://api.anthropic.com/v1/oauth/token"

    // MARK: - PKCE

    /// `SystemRandomNumberGenerator` is CSPRNG-backed on Apple platforms.
    static func randomURLSafeString(byteCount: Int = 32) -> String {
        base64URL(Data((0..<byteCount).map { _ in UInt8.random(in: .min ... .max) }))
    }

    static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Authorize URL

    static func authorizeURL(codeChallenge: String, state: String) throws -> URL {
        guard var components = URLComponents(string: authorizeEndpoint) else {
            throw APIError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components.url else { throw APIError.invalidURL }
        return url
    }
}

// MARK: - Credentials

/// The stored OAuth token set. Mirrors Claude Code's own credential blob so
/// the shape is familiar if it ever needs inspecting by hand.
public struct OAuthCredentials: Codable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

extension OAuthService {
    /// Refresh this far ahead of expiry so a poll never races the clock.
    static let refreshWindow: TimeInterval = 300

    static func needsRefresh(_ credentials: OAuthCredentials, now: Date = Date()) -> Bool {
        credentials.expiresAt.timeIntervalSince(now) < refreshWindow
    }

    static func parseTokenResponse(
        data: Data,
        now: Date = Date(),
        previousRefreshToken: String? = nil
    ) throws -> OAuthCredentials {
        struct TokenResponse: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresIn: Double
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(TokenResponse.self, from: data)
        guard let refreshToken = response.refreshToken ?? previousRefreshToken else {
            throw OAuthError.tokenExchangeFailed(200)
        }
        return OAuthCredentials(
            accessToken: response.accessToken,
            refreshToken: refreshToken,
            expiresAt: now.addingTimeInterval(response.expiresIn)
        )
    }

    // MARK: - Flow

    /// Full browser sign-in: PKCE pair → listener → consent page → code exchange.
    public static func signIn() async throws -> OAuthCredentials {
        let verifier = randomURLSafeString()
        let state = randomURLSafeString(byteCount: 16)
        let server = OAuthCallbackServer()
        let url = try authorizeURL(codeChallenge: codeChallenge(for: verifier), state: state)

        // The listener starts first; the browser can't beat it to the port
        // because the user still has to approve on the consent page.
        async let callback = server.waitForCallback()
        NSWorkspace.shared.open(url)
        let params = try await callback

        if let error = params["error"] { throw OAuthError.denied(error) }
        guard params["state"] == state else { throw OAuthError.stateMismatch }
        guard let code = params["code"] else { throw OAuthError.denied("missing_code") }

        return try await exchange(body: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
            "state": state,
        ])
    }

    public static func refresh(_ credentials: OAuthCredentials) async throws -> OAuthCredentials {
        try await exchange(
            body: [
                "grant_type": "refresh_token",
                "refresh_token": credentials.refreshToken,
                "client_id": clientID,
            ],
            previousRefreshToken: credentials.refreshToken
        )
    }

    private static func exchange(
        body: [String: String],
        previousRefreshToken: String? = nil
    ) async throws -> OAuthCredentials {
        guard let url = URL(string: tokenEndpoint) else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Verified in task 0: without these two headers the endpoint 400s
        // with a generic invalid_request_error, even though the JSON body is
        // well-formed.
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard http.statusCode == 200 else { throw OAuthError.tokenExchangeFailed(http.statusCode) }
        return try parseTokenResponse(data: data, previousRefreshToken: previousRefreshToken)
    }

    // MARK: - Storage

    public static let keychainAccount = "oauth_credentials"

    public static func load(from keychain: any KeychainServicing) throws -> OAuthCredentials? {
        guard let json = try keychain.retrieve(account: keychainAccount) else { return nil }
        return try? JSONDecoder().decode(OAuthCredentials.self, from: Data(json.utf8))
    }

    public static func save(_ credentials: OAuthCredentials, to keychain: any KeychainServicing) throws {
        let data = try JSONEncoder().encode(credentials)
        try keychain.save(account: keychainAccount, value: String(decoding: data, as: UTF8.self))
    }

    public static func clear(from keychain: any KeychainServicing) {
        try? keychain.delete(account: keychainAccount)
    }
}
