import Testing
@testable import ClaudeBarUI

@MainActor
@Suite
struct ClaudeAPIClientTests {
    @Test func parseUsageResponse() throws {
        let json = """
        {
          "five_hour": { "utilization": 73.0, "resets_at": "2026-04-12T15:30:00.000Z" },
          "seven_day": { "utilization": 31.0, "resets_at": "2026-04-14T12:59:00.000Z" },
          "seven_day_sonnet": { "utilization": 20.0, "resets_at": "2026-04-14T12:59:00.000Z" },
          "seven_day_opus": { "utilization": 8.0, "resets_at": null }
        }
        """.data(using: .utf8)!

        let usage = try ClaudeAPIClient.parseUsageResponse(data: json)
        #expect(abs(usage.fiveHour!.utilization - 0.73) < 0.0001)
        #expect(abs(usage.sevenDay.utilization - 0.31) < 0.0001)
        #expect(abs(usage.sevenDaySonnet!.utilization - 0.20) < 0.0001)
    }

    @Test func buildPlatformOrganizationsRequest() throws {
        let request = try ClaudeAPIClient.buildPlatformOrganizationsRequest(platformSessionKey: "sk-test")
        #expect(request.url?.absoluteString == "https://platform.claude.com/api/organizations")
        #expect(request.value(forHTTPHeaderField: "Cookie") == "sessionKey=sk-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-client-platform") == "web_console")
        #expect(request.httpMethod == "GET")
    }

    @Test func buildPlatformCreditsRequest() throws {
        let request = try ClaudeAPIClient.buildPlatformCreditsRequest(
            platformSessionKey: "sk-test",
            platformOrgId: "8bc28b46-d6dd-4982-a38a-66a11be1c437"
        )
        #expect(request.url?.absoluteString == "https://platform.claude.com/api/organizations/8bc28b46-d6dd-4982-a38a-66a11be1c437/prepaid/credits")
        #expect(request.value(forHTTPHeaderField: "Cookie") == "sessionKey=sk-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-client-platform") == "web_console")
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://platform.claude.com/settings/billing")
    }

    @Test func parsePlatformOrganizationsIgnoresExtraFields() throws {
        let json = """
        [
          {
            "id": 136002694,
            "uuid": "4f4dee87-d910-4390-ae54-b64ad23b9243",
            "name": "Personal",
            "settings": { "claude_console_privacy": "default_private" },
            "capabilities": ["claude_pro", "chat"],
            "billing_type": "stripe_subscription"
          },
          {
            "id": 151870534,
            "uuid": "8bc28b46-d6dd-4982-a38a-66a11be1c437",
            "name": "Vova's Individual Org",
            "settings": {},
            "capabilities": ["api", "api_individual"],
            "billing_type": "api_evaluation"
          }
        ]
        """.data(using: .utf8)!

        let orgs = try ClaudeAPIClient.parsePlatformOrganizationsResponse(data: json)
        #expect(orgs.count == 2)
        #expect(orgs[1].uuid == "8bc28b46-d6dd-4982-a38a-66a11be1c437")
        #expect(orgs[1].capabilities?.contains("api") == true)
    }

    @Test func parsePlatformCreditsHappyPath() throws {
        let json = """
        {
          "amount": 189,
          "currency": "USD",
          "auto_reload_settings": null,
          "pending_invoice_amount_cents": null,
          "last_paid_purchase_cents": null
        }
        """.data(using: .utf8)!

        let credits = try ClaudeAPIClient.parsePlatformCreditsResponse(data: json)
        #expect(credits != nil)
        #expect(credits?.amountCents == 189)
        #expect(credits?.currency == "USD")
    }

    @Test func parsePlatformCreditsReturnsNilOnPermissionError() throws {
        let json = """
        {
          "type": "error",
          "error": {
            "type": "permission_error",
            "message": "Invalid authorization for organization",
            "details": { "error_visibility": "user_facing" }
          },
          "request_id": "req_011CarEk9gJt4F4znLHquZ25"
        }
        """.data(using: .utf8)!

        let credits = try ClaudeAPIClient.parsePlatformCreditsResponse(data: json)
        #expect(credits == nil)
    }

    @Test func buildOAuthUsageRequest() throws {
        let request = try ClaudeAPIClient.buildOAuthRequest(path: "/api/oauth/usage", accessToken: "sk-at-123")

        #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-at-123")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.httpMethod == "GET")
    }

    @Test func parseOAuthProfileResponse() throws {
        let json = """
        {
          "account": { "uuid": "acct-1", "email": "user@example.com", "has_claude_max": true },
          "organization": {
            "uuid": "org-1",
            "name": "Personal",
            "organization_type": "claude_personal",
            "rate_limit_tier": "default_claude_max_5x",
            "seat_tier": null,
            "subscription_status": "active"
          },
          "enabled_plugins": []
        }
        """.data(using: .utf8)!

        let result = try ClaudeAPIClient.parseProfileResponse(data: json)
        #expect(result.organization.uuid == "org-1")
        #expect(result.organization.name == "Personal")
        #expect(result.organization.tier == .max5x)
        #expect(result.account.uuid == "acct-1")
        #expect(result.account.email == "user@example.com")
    }

    /// Real payload captured from /api/oauth/usage on 2026-08-10 — the schema
    /// the app must keep parsing, including 6-digit fractional seconds with a
    /// +00:00 offset and the model-scoped weekly limit.
    @Test func parseUsageResponseFromOAuthEndpoint() throws {
        let json = """
        {
          "five_hour": { "utilization": 66.0, "resets_at": "2026-08-10T10:39:59.049791+00:00",
                         "limit_dollars": null, "used_dollars": null, "remaining_dollars": null },
          "seven_day": { "utilization": 51.0, "resets_at": "2026-08-13T03:59:59.049824+00:00",
                         "limit_dollars": null, "used_dollars": null, "remaining_dollars": null },
          "seven_day_opus": null,
          "seven_day_sonnet": null,
          "nimbus_quill": { "utilization": 0.0, "resets_at": null,
                            "limit_dollars": null, "used_dollars": null, "remaining_dollars": null },
          "cinder_cove": null,
          "extra_usage": { "is_enabled": false, "monthly_limit": null, "used_credits": null,
                           "utilization": null, "user_disabled": false },
          "limits": [
            { "kind": "session", "group": "session", "percent": 66, "severity": "normal",
              "resets_at": "2026-08-10T10:39:59.049791+00:00", "scope": null, "is_active": true },
            { "kind": "weekly_all", "group": "weekly", "percent": 51, "severity": "normal",
              "resets_at": "2026-08-13T03:59:59.049824+00:00", "scope": null, "is_active": false },
            { "kind": "weekly_scoped", "group": "weekly", "percent": 53, "severity": "normal",
              "resets_at": "2026-08-13T04:00:00.050030+00:00",
              "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null },
              "is_active": false }
          ],
          "spend": { "used": { "amount_minor": 0, "currency": "USD", "exponent": 2 },
                     "percent": 0, "severity": "normal", "enabled": false },
          "member_dashboard_available": false
        }
        """.data(using: .utf8)!

        let usage = try ClaudeAPIClient.parseUsageResponse(data: json)
        #expect(abs(usage.fiveHour!.utilization - 0.66) < 0.0001)
        #expect(abs(usage.sevenDay.utilization - 0.51) < 0.0001)
        #expect(usage.fiveHour?.resetsAt != nil)
        // The model-scoped weekly limit becomes a per-model window labelled "Fable".
        let fable = usage.additionalWindows.first { $0.key == "sevenDayFable" }
        #expect(fable != nil)
        #expect(abs((fable?.utilization ?? 0) - 0.53) < 0.0001)
        #expect(usage.isMaxTier == false)
    }
}
