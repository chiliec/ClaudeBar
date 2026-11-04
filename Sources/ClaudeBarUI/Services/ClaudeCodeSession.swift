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

/// Reads the CLI's item through `/usr/bin/security` rather than SecItem. The CLI
/// writes it with `security add-generic-password -U`, which resets the item's
/// partition list to `apple-tool:` on every token refresh -- wiping any "Always
/// Allow" granted to ClaudeBar, so a direct read prompts for the login password
/// again after each refresh. `security` itself always stays trusted. Read-only
/// by construction: see `ClaudeCodeSession`.
public struct SecurityToolKeychain: KeychainServicing {
    public let serviceName: String

    public init(serviceName: String = ClaudeCodeSession.serviceName) {
        self.serviceName = serviceName
    }

    public func retrieve(account: String) throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", serviceName, "-a", account, "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus == 44 { return nil }   // errSecItemNotFound
        guard process.terminationStatus == 0 else {
            throw KeychainError.retrieveFailed(OSStatus(process.terminationStatus))
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines)
    }

    public func save(account: String, value: String) throws {
        throw KeychainError.saveFailed(errSecWrPerm)
    }

    public func delete(account: String) throws {
        throw KeychainError.deleteFailed(errSecWrPerm)
    }
}
