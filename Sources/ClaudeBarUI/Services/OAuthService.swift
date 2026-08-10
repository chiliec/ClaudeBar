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
