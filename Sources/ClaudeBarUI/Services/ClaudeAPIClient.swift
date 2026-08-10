import Foundation

public struct ClaudeAPIClient {
    // MARK: - Response Parsers

    public static func parseUsageResponse(data: Data) throws -> UsageResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)
            let formatters = [ISO8601DateFormatter.withFractionalSeconds, ISO8601DateFormatter.standard]
            for formatter in formatters {
                if let date = formatter.date(from: dateString) { return date }
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot parse date: \(dateString)")
        }
        return try decoder.decode(UsageResponse.self, from: data)
    }

    static func validateHTTPResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        switch http.statusCode {
        case 200: return
        case 401, 403: throw APIError.sessionExpired
        case 429: throw APIError.rateLimited
        default: throw APIError.httpError(http.statusCode)
        }
    }
}

public enum APIError: Error, Equatable {
    case invalidURL
    case invalidResponse
    case sessionExpired
    case rateLimited
    case httpError(Int)

    public var displayMessage: String {
        switch self {
        case .invalidURL: return String(localized: "apiError.invalidURL", bundle: .module)
        case .invalidResponse: return String(localized: "apiError.invalidResponse", bundle: .module)
        case .sessionExpired: return String(localized: "apiError.sessionExpired", bundle: .module)
        case .rateLimited: return String(localized: "apiError.rateLimited", bundle: .module)
        case .httpError(let code): return String(localized: "apiError.httpError \(code)", bundle: .module)
        }
    }
}

extension ISO8601DateFormatter {
    static let withFractionalSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let standard: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

// MARK: - OAuth data endpoints (api.anthropic.com)

public struct AccountIdentity: Equatable {
    public let uuid: String
    public let email: String
    public init(uuid: String, email: String) { self.uuid = uuid; self.email = email }
}

public struct ProfileResult: Equatable {
    public let account: AccountIdentity
    public let organization: OrganizationDetails
    public init(account: AccountIdentity, organization: OrganizationDetails) {
        self.account = account
        self.organization = organization
    }
}

extension ClaudeAPIClient {
    private static let oauthBaseURL = "https://api.anthropic.com"
    private static let oauthBetaHeader = "oauth-2025-04-20"

    public static func buildOAuthRequest(path: String, accessToken: String) throws -> URLRequest {
        guard let url = URL(string: "\(oauthBaseURL)\(path)") else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(oauthBetaHeader, forHTTPHeaderField: "anthropic-beta")
        return request
    }

    /// Maps `/api/oauth/profile` onto the existing `OrganizationDetails` so the
    /// tier pill and header name keep working unchanged.
    public static func parseProfileResponse(data: Data) throws -> ProfileResult {
        struct Envelope: Decodable {
            struct Account: Decodable { let uuid: String; let email: String }
            struct Org: Decodable {
                let uuid: String
                let name: String
                let rateLimitTier: String?
            }
            let account: Account
            let organization: Org
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let envelope = try decoder.decode(Envelope.self, from: data)
        return ProfileResult(
            account: AccountIdentity(uuid: envelope.account.uuid, email: envelope.account.email),
            organization: OrganizationDetails(
                uuid: envelope.organization.uuid,
                name: envelope.organization.name,
                rateLimitTier: envelope.organization.rateLimitTier
            )
        )
    }

    public static func fetchOAuthUsage(accessToken: String) async throws -> UsageResponse {
        let request = try buildOAuthRequest(path: "/api/oauth/usage", accessToken: accessToken)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTPResponse(response)
        return try parseUsageResponse(data: data)
    }

    public static func fetchOAuthProfile(accessToken: String) async throws -> ProfileResult {
        let request = try buildOAuthRequest(path: "/api/oauth/profile", accessToken: accessToken)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTPResponse(response)
        return try parseProfileResponse(data: data)
    }
}

// MARK: - platform.claude.com (prepaid API credits)

public enum PlatformAuthError: Error, Equatable {
    /// 401/403 from platform.claude.com — clear ONLY the platform key.
    /// Distinct from APIError.sessionExpired which owns the claude.ai key.
    case sessionExpired
    /// Listing returned 200 but no org has the `api` capability.
    case noApiOrg
}

extension ClaudeAPIClient {
    private static let platformBaseURL = "https://platform.claude.com"

    private static func applyPlatformHeaders(_ request: inout URLRequest, platformSessionKey: String) {
        request.setValue("sessionKey=\(platformSessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("web_console", forHTTPHeaderField: "anthropic-client-platform")
        request.setValue("https://platform.claude.com/settings/billing", forHTTPHeaderField: "Referer")
    }

    public static func buildPlatformOrganizationsRequest(platformSessionKey: String) throws -> URLRequest {
        guard let url = URL(string: "\(platformBaseURL)/api/organizations") else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyPlatformHeaders(&request, platformSessionKey: platformSessionKey)
        return request
    }

    public static func buildPlatformCreditsRequest(platformSessionKey: String, platformOrgId: String) throws -> URLRequest {
        guard let url = URL(string: "\(platformBaseURL)/api/organizations/\(platformOrgId)/prepaid/credits") else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyPlatformHeaders(&request, platformSessionKey: platformSessionKey)
        return request
    }

    public static func parsePlatformOrganizationsResponse(data: Data) throws -> [Organization] {
        return try JSONDecoder().decode([Organization].self, from: data)
    }

    /// Parse the prepaid credits response. Returns `nil` for the
    /// `permission_error` 200 body (session valid, org has no credits).
    public static func parsePlatformCreditsResponse(data: Data) throws -> PlatformCredits? {
        struct ErrorEnvelope: Decodable {
            struct Inner: Decodable { let type: String }
            let type: String
            let error: Inner
        }
        if let env = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
           env.type == "error" {
            return nil
        }
        return try JSONDecoder().decode(PlatformCredits.self, from: data)
    }

    /// Like `validateHTTPResponse` but maps 401/403 to `PlatformAuthError.sessionExpired`
    /// instead of `APIError.sessionExpired`. Critical: a platform-side 401/403 must NOT
    /// drag the user through the global handleSessionExpired() flow that wipes the
    /// claude.ai key and ejects to SetupView.
    static func validatePlatformHTTPResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        switch http.statusCode {
        case 200: return
        case 401, 403: throw PlatformAuthError.sessionExpired
        case 429: throw APIError.rateLimited
        default: throw APIError.httpError(http.statusCode)
        }
    }

    public static func fetchPlatformOrganizations(platformSessionKey: String) async throws -> [Organization] {
        let request = try buildPlatformOrganizationsRequest(platformSessionKey: platformSessionKey)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validatePlatformHTTPResponse(response)
        return try parsePlatformOrganizationsResponse(data: data)
    }

    /// Returns `nil` when the org has no prepaid credits (permission_error 200).
    /// Throws `PlatformAuthError.sessionExpired` on 401/403.
    public static func fetchPlatformCredits(platformSessionKey: String, platformOrgId: String) async throws -> PlatformCredits? {
        let request = try buildPlatformCreditsRequest(platformSessionKey: platformSessionKey, platformOrgId: platformOrgId)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validatePlatformHTTPResponse(response)
        return try parsePlatformCreditsResponse(data: data)
    }
}
