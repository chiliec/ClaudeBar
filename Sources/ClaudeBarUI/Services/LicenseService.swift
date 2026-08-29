import Foundation

/// Lemon Squeezy license validation for ClaudeBar Pro.
///
/// Lemon Squeezy is a Merchant of Record: it collects and remits global tax and
/// pays out to the seller with no US entity required. The license key itself is
/// the credential — these endpoints take no Authorization header.
///
/// This service is intentionally a thin, injectable struct mirroring
/// `KeychainService`: it performs the three network calls and returns typed
/// results. All persistence and the unlock decision live in `LicenseStore`.
public protocol LicenseServicing: Sendable {
    /// Activate a freshly-pasted key on this machine. Returns the instance id to persist.
    func activate(key: String, instanceName: String) async throws -> LicenseActivation
    /// Re-check a stored key. Called at launch and daily.
    func validate(key: String, instanceId: String) async throws -> LicenseValidation
    /// Release this machine's activation slot ("Sign out this Mac").
    func deactivate(key: String, instanceId: String) async throws -> Bool
}

/// Result of a successful activation.
public struct LicenseActivation: Sendable, Equatable {
    public let activated: Bool
    public let instanceId: String?
    public let status: String?
    public let error: String?
}

/// Result of a validation check.
public struct LicenseValidation: Sendable, Equatable {
    public let valid: Bool
    public let status: String?
    public let expiresAt: Date?
    public let error: String?

    /// The key is genuinely Pro iff the server says valid, the status is active,
    /// and it hasn't expired.
    public var grantsPro: Bool {
        guard valid, status == "active" else { return false }
        if let expiresAt { return expiresAt > Date() }
        return true
    }
}

/// Thrown only for network-level failures (unreachable server / timeout), so the
/// caller can distinguish "couldn't reach LS" (→ offline grace) from an
/// authoritative "invalid" answer (→ revoke now).
public struct LicenseNetworkError: Error {
    public let underlying: Error
    public init(_ underlying: Error) { self.underlying = underlying }
}

public struct LicenseService: LicenseServicing {
    private let base = URL(string: "https://api.lemonsqueezy.com/v1/licenses")!
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func activate(key: String, instanceName: String) async throws -> LicenseActivation {
        let json = try await post("activate", ["license_key": key, "instance_name": instanceName])
        let instance = json["instance"] as? [String: Any]
        let lk = json["license_key"] as? [String: Any]
        return LicenseActivation(
            activated: json["activated"] as? Bool ?? false,
            instanceId: instance?["id"] as? String,
            status: lk?["status"] as? String,
            error: json["error"] as? String
        )
    }

    public func validate(key: String, instanceId: String) async throws -> LicenseValidation {
        let json = try await post("validate", ["license_key": key, "instance_id": instanceId])
        let lk = json["license_key"] as? [String: Any]
        return LicenseValidation(
            valid: json["valid"] as? Bool ?? false,
            status: lk?["status"] as? String,
            expiresAt: Self.parseDate(lk?["expires_at"]),
            error: json["error"] as? String
        )
    }

    public func deactivate(key: String, instanceId: String) async throws -> Bool {
        let json = try await post("deactivate", ["license_key": key, "instance_id": instanceId])
        return json["deactivated"] as? Bool ?? false
    }

    // MARK: - Transport

    /// POST form-encoded params. A transport failure (unreachable/timeout) is
    /// wrapped in `LicenseNetworkError`; a reachable server that returns an error
    /// body (e.g. a bad key → HTTP 400 with `{error: ...}`) is decoded normally,
    /// because that is an authoritative answer, not a connectivity problem.
    private func post(_ path: String, _ params: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formEncode(params).data(using: .utf8)

        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch {
            throw LicenseNetworkError(error)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LicenseNetworkError(URLError(.cannotParseResponse))
        }
        return json
    }

    private static func formEncode(_ params: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return params
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
    }

    private static func parseDate(_ raw: Any?) -> Date? {
        guard let s = raw as? String else { return nil }
        return ISO8601DateFormatter().date(from: s)
            ?? ISO8601DateFormatter.withFractionalSeconds.date(from: s)
    }
}
