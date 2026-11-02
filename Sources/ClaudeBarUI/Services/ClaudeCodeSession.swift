import Foundation

/// Read-only access to Claude Code CLI's own OAuth login. Never refresh or
/// write these tokens: refresh tokens rotate, so a ClaudeBar refresh would
/// invalidate the CLI's copy and force a `/login`.
public enum ClaudeCodeSession {
    public static let serviceName = "Claude Code-credentials"

    static func parse(_ json: String) -> OAuthCredentials? {
        struct Blob: Decodable {
            struct OAuth: Decodable {
                let accessToken: String
                let refreshToken: String
                let expiresAt: Double   // Unix milliseconds
            }
            let claudeAiOauth: OAuth
        }
        guard let o = try? JSONDecoder().decode(Blob.self, from: Data(json.utf8)).claudeAiOauth else { return nil }
        return OAuthCredentials(accessToken: o.accessToken, refreshToken: o.refreshToken,
                                expiresAt: Date(timeIntervalSince1970: o.expiresAt / 1000))
    }

    /// The CLI files its item under the login user's name.
    static func load(from keychain: any KeychainServicing) -> OAuthCredentials? {
        guard let json = try? keychain.retrieve(account: NSUserName()) else { return nil }
        return parse(json)
    }
}
