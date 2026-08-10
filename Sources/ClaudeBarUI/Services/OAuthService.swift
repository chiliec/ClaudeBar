import AppKit
import CryptoKit
import Foundation

/// Failures specific to the browser sign-in flow. Distinct from `APIError`
/// (which owns data-endpoint failures) and `PlatformAuthError` (which owns the
/// platform.claude.com cookie).
public enum OAuthError: Error, Equatable {
    /// The loopback listener could not bind an ephemeral port.
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

/// Bridges the callback server's synchronous `onPortBound` closure (fired
/// from its network queue) to a single `await`. Delivers the port — or the
/// bind failure — whether `wait()` is called before or after `fulfill(_:)`.
/// First fulfillment wins; later ones are ignored.
private final class PortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<UInt16, Error>?
    private var continuation: CheckedContinuation<Result<UInt16, Error>, Never>?

    func fulfill(_ result: Result<UInt16, Error>) {
        lock.lock()
        defer { lock.unlock() }
        if let continuation {
            continuation.resume(returning: result)
            self.continuation = nil
        } else if self.result == nil {
            self.result = result
        }
    }

    func wait() async -> Result<UInt16, Error> {
        lock.lock()
        if let result {
            lock.unlock()
            return result
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            lock.unlock()
        }
    }
}

public enum OAuthService {
    /// Claude Code's public client ID — no third-party OAuth registration
    /// exists for claude.ai, so this app authenticates as Claude Code. If
    /// Anthropic ever revokes or scopes it down, sign-in breaks visibly at
    /// the consent page.
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    /// Matches Claude Code CLI's own loopback server, which binds an
    /// OS-assigned ephemeral port (`.listen(0, "127.0.0.1")`) rather than a
    /// fixed one — a fixed port here got rejected server-side with
    /// "Invalid request format".
    static func redirectURI(port: UInt16) -> String { "http://localhost:\(port)/callback" }
    /// Claude Code CLI never requests `user:profile` alone — its authorize
    /// calls always send this full default scope set (or the inference-only
    /// singleton). A narrower custom scope is likely an unrecognized
    /// combination for this client_id, which matches the "Invalid request
    /// format" rejection seen with a `user:profile`-only request.
    public static let scope = "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
    /// Matches Claude Code CLI's own `CLAUDE_AI_AUTHORIZE_URL` / `TOKEN_URL`
    /// (extracted from its shipped binary — claude.ai/oauth/authorize and
    /// api.anthropic.com/v1/oauth/token both rejected real requests with a
    /// claude.ai-branded "Authorization failed" page).
    static let authorizeEndpoint = "https://claude.com/cai/oauth/authorize"
    static let tokenEndpoint = "https://platform.claude.com/v1/oauth/token"

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

    static func authorizeURL(codeChallenge: String, state: String, port: UInt16) throws -> URL {
        // Byte-for-byte parity with the URL Claude Code's CLI builds
        // (captured live from v2.1.220): same parameter order, and spaces
        // encoded as `+` the way URLSearchParams serializes them — in case
        // the endpoint's schema validation is strict about the raw query.
        let params: [(String, String)] = [
            ("code", "true"),
            ("client_id", clientID),
            ("response_type", "code"),
            ("redirect_uri", redirectURI(port: port)),
            ("scope", scope),
            ("code_challenge", codeChallenge),
            ("code_challenge_method", "S256"),
            ("state", state),
        ]
        let query = params
            .map { "\($0.0)=\(encodeURIComponent($0.1).replacingOccurrences(of: "%20", with: "+"))" }
            .joined(separator: "&")
        guard let url = URL(string: "\(authorizeEndpoint)?\(query)") else {
            throw APIError.invalidURL
        }
        return url
    }

    /// Matches JavaScript's `encodeURIComponent` allowed-character set.
    static func encodeURIComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
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
        // 32 bytes, matching the CLI's own state parameter (43 chars base64url).
        let state = randomURLSafeString()
        let server = OAuthCallbackServer()
        let portBox = PortBox()

        let callbackTask = Task {
            do {
                return try await server.waitForCallback { port in portBox.fulfill(.success(port)) }
            } catch {
                // A bind failure lands here before any port was delivered, so
                // the `wait()` below throws instead of hanging. Later errors
                // (timeout) are ignored by the box and rethrow from
                // `callbackTask.value` instead.
                portBox.fulfill(.failure(error))
                throw error
            }
        }

        let port = try await portBox.wait().get()

        let url = try authorizeURL(codeChallenge: codeChallenge(for: verifier), state: state, port: port)
        NSWorkspace.shared.open(url)
        let params = try await callbackTask.value

        if let error = params["error"] { throw OAuthError.denied(error) }
        guard params["state"] == state else { throw OAuthError.stateMismatch }
        guard let code = params["code"] else { throw OAuthError.denied("missing_code") }

        return try await exchange(body: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI(port: port),
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
