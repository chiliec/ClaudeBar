import Testing
import Foundation
@testable import ClaudeBarUI

@Suite
struct UsageModelTests {
    @Test func decodeFullUsageResponse() throws {
        let json = """
        {
          "five_hour": { "utilization": 42.0, "resets_at": "2026-04-12T15:30:00.000Z" },
          "seven_day": { "utilization": 15.0, "resets_at": "2026-04-14T12:59:00.000Z" },
          "seven_day_sonnet": { "utilization": 8.0, "resets_at": "2026-04-14T12:59:00.000Z" },
          "seven_day_opus": { "utilization": 3.0, "resets_at": null },
          "extra_usage": { "is_enabled": true, "monthly_limit": 100.0, "used_credits": 12.50, "utilization": 12.5 }
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601

        let usage = try decoder.decode(UsageResponse.self, from: json)

        #expect(abs(usage.fiveHour!.utilization - 0.42) < 0.0001)
        #expect(usage.fiveHour?.resetsAt != nil)
        #expect(abs(usage.sevenDay.utilization - 0.15) < 0.0001)
        #expect(abs(usage.sevenDaySonnet!.utilization - 0.08) < 0.0001)
        #expect(abs(usage.sevenDayOpus!.utilization - 0.03) < 0.0001)
        #expect(usage.sevenDayOpus?.resetsAt == nil)
        #expect(usage.extraUsage?.isEnabled == true)
        #expect(usage.extraUsage?.monthlyLimit == 100.0)
        #expect(usage.extraUsage?.usedCredits == 12.50)
    }

    @Test func decodeMinimalResponse() throws {
        let json = """
        {
          "seven_day": { "utilization": 5.0, "resets_at": "2026-04-14T12:59:00.000Z" }
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601

        let usage = try decoder.decode(UsageResponse.self, from: json)

        #expect(usage.fiveHour == nil)
        #expect(abs(usage.sevenDay.utilization - 0.05) < 0.0001)
        #expect(usage.sevenDaySonnet == nil)
        #expect(usage.sevenDayOpus == nil)
        #expect(usage.extraUsage == nil)
    }

    @Test func decodeOnePercentDoesNotClipToFull() throws {
        let json = """
        { "seven_day": { "utilization": 1.0, "resets_at": null } }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601

        let usage = try decoder.decode(UsageResponse.self, from: json)

        #expect(abs(usage.sevenDay.utilization - 0.01) < 0.0001)
    }

    @Test func surfacesCodenamedWindowsGenerically() throws {
        // Real 2026-06 payload shape: per-model windows are null, but the API
        // carries a codenamed dollar-pool (`amber_ladder`) plus several null
        // codenames that must be ignored.
        let json = """
        {
          "five_hour": {"utilization": 50.0, "resets_at": "2026-06-25T16:00:00.631702+00:00"},
          "seven_day": {"utilization": 12.0, "resets_at": "2026-07-01T12:00:00.631730+00:00"},
          "seven_day_oauth_apps": null,
          "seven_day_opus": null,
          "seven_day_sonnet": null,
          "seven_day_omelette": null,
          "tangelo": null,
          "cinder_cove": null,
          "amber_ladder": {"utilization": 0.0, "resets_at": "2026-09-02T06:59:59+00:00", "limit_dollars": 2500, "used_dollars": 0.0, "remaining_dollars": 2500.0},
          "extra_usage": {"is_enabled": false, "monthly_limit": null, "used_credits": null, "utilization": null, "currency": "USD"},
          "limits": [{"kind": "session", "percent": 50}],
          "spend": {"percent": 0, "enabled": false}
        }
        """.data(using: .utf8)!

        let usage = try ClaudeAPIClient.parseUsageResponse(data: json)

        // Null windows and structured fields are excluded; only the live pool remains.
        #expect(usage.additionalWindows.count == 1)
        let amber = try #require(usage.additionalWindows.first)
        #expect(amber.key == "amberLadder")
        #expect(amber.displayName == "Amber Ladder")
        #expect(amber.isDollarPool)
        #expect(amber.limitDollars == 2500)
        #expect(amber.usedDollars == 0)
        #expect(abs(amber.utilization - 0.0) < 0.0001)
        #expect(amber.resetsAt != nil)
        // Typed shims agree the per-model windows are gone.
        #expect(usage.sevenDaySonnet == nil)
        #expect(usage.sevenDayOmelette == nil)
    }

    @Test func ordersKnownModelWindowsBeforeCodenames() throws {
        let json = """
        {
          "seven_day": {"utilization": 10.0, "resets_at": null},
          "amber_ladder": {"utilization": 0.0, "resets_at": null, "limit_dollars": 100},
          "seven_day_sonnet": {"utilization": 5.0, "resets_at": null},
          "seven_day_opus": {"utilization": 2.0, "resets_at": null}
        }
        """.data(using: .utf8)!

        let usage = try ClaudeAPIClient.parseUsageResponse(data: json)
        #expect(usage.additionalWindows.map(\.key) == ["sevenDaySonnet", "sevenDayOpus", "amberLadder"])
    }

    @Test func surfacesModelScopedWeeklyLimitFromLimitsArray() throws {
        // Real 2026-07 payload shape: the per-model `seven_day_*` windows are all
        // null and the model-specific weekly limit has moved into `limits` as a
        // `weekly_scoped` entry naming the model via `scope.model.display_name`.
        let json = """
        {
          "five_hour": {"utilization": 21.0, "resets_at": "2026-07-09T07:00:00.409744+00:00"},
          "seven_day": {"utilization": 9.0, "resets_at": "2026-07-15T12:00:00.409767+00:00"},
          "seven_day_sonnet": null,
          "seven_day_opus": null,
          "seven_day_omelette": null,
          "amber_ladder": {"utilization": 0.0, "resets_at": "2026-09-02T06:59:59+00:00", "limit_dollars": 2500, "used_dollars": 0.0, "remaining_dollars": 2500.0},
          "cinder_cove": null,
          "limits": [
            {"kind": "session", "group": "session", "percent": 21, "resets_at": "2026-07-09T07:00:00.409744+00:00", "scope": null, "is_active": true},
            {"kind": "weekly_all", "group": "weekly", "percent": 9, "resets_at": "2026-07-15T12:00:00.409767+00:00", "scope": null, "is_active": false},
            {"kind": "weekly_scoped", "group": "weekly", "percent": 5, "resets_at": "2026-07-15T12:00:00.410131+00:00", "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}, "is_active": false}
          ]
        }
        """.data(using: .utf8)!

        let usage = try ClaudeAPIClient.parseUsageResponse(data: json)

        // A model-scoped Fable window is synthesized from the limits array, and
        // sorts ahead of the codenamed dollar pool.
        #expect(usage.additionalWindows.map(\.key) == ["sevenDayFable", "amberLadder"])
        let fable = try #require(usage.additionalWindows.first)
        #expect(fable.isModelScoped)
        #expect(fable.displayName == "Fable")
        #expect(!fable.isDollarPool)
        #expect(abs(fable.utilization - 0.05) < 0.0001)
        #expect(fable.resetsAt != nil)
        // session / weekly_all limits are not turned into windows (they already
        // map to five_hour / seven_day).
        #expect(!usage.additionalWindows.contains { $0.key.contains("eekly") || $0.key.contains("ession") })
    }

    @Test func humanizesUnknownCodenames() {
        #expect(AdditionalWindow(key: "amberLadder", utilization: 0, resetsAt: nil).displayName == "Amber Ladder")
        #expect(AdditionalWindow(key: "iguanaNecktie", utilization: 0, resetsAt: nil).displayName == "Iguana Necktie")
        #expect(AdditionalWindow(key: "tangelo", utilization: 0, resetsAt: nil).displayName == "Tangelo")
        // Known codenames keep their curated name.
        #expect(AdditionalWindow(key: "sevenDaySonnet", utilization: 0, resetsAt: nil).displayName == "Sonnet")
    }

    @Test func decodeOrganization() throws {
        let json = """
        [{ "uuid": "abc-123", "name": "My Org", "capabilities": ["chat"] }]
        """.data(using: .utf8)!

        let orgs = try JSONDecoder().decode([Organization].self, from: json)

        #expect(orgs.count == 1)
        #expect(orgs[0].uuid == "abc-123")
        #expect(orgs[0].name == "My Org")
    }

    @Test func decodeMaxPayloadWithNullOpus() throws {
        // Real Max payload shape observed 2026-04: seven_day_opus is explicitly
        // null when the user hasn't used Opus this week. Ensures we keep parsing
        // these responses instead of falling over.
        let json = """
        {
          "five_hour": {"utilization": 10.0, "resets_at": "2026-04-24T00:50:00.605270+00:00"},
          "seven_day": {"utilization": 2.0, "resets_at": "2026-04-28T19:00:00.605293+00:00"},
          "seven_day_oauth_apps": null,
          "seven_day_opus": null,
          "seven_day_sonnet": {"utilization": 0.0, "resets_at": null},
          "seven_day_omelette": {"utilization": 0.0, "resets_at": null},
          "extra_usage": {"is_enabled": true, "monthly_limit": 1500, "used_credits": 652.0, "utilization": 43.46, "currency": "USD"}
        }
        """.data(using: .utf8)!

        let usage = try ClaudeAPIClient.parseUsageResponse(data: json)

        #expect(usage.sevenDayOpus == nil)
        #expect(usage.sevenDaySonnet != nil)
        #expect(abs(usage.sevenDaySonnet!.utilization - 0.0) < 0.0001)
        #expect(usage.sevenDayOmelette != nil)
        #expect(usage.extraUsage?.currency == "USD")
        #expect(usage.extraUsage?.monthlyLimit == 1500)
        #expect(usage.isMaxTier == true)
    }

    @Test func proTierWhenNoExtraUsage() throws {
        let json = """
        { "seven_day": {"utilization": 20.0, "resets_at": null} }
        """.data(using: .utf8)!

        let usage = try ClaudeAPIClient.parseUsageResponse(data: json)
        #expect(usage.isMaxTier == false)
    }

    @Test func proTierWhenExtraUsageDisabled() throws {
        let json = """
        {
          "seven_day": {"utilization": 20.0, "resets_at": null},
          "extra_usage": {"is_enabled": false, "monthly_limit": 0, "used_credits": 0, "utilization": 0}
        }
        """.data(using: .utf8)!

        let usage = try ClaudeAPIClient.parseUsageResponse(data: json)
        #expect(usage.isMaxTier == false)
    }

    @Test func decodeExtraUsageWithOverageBalance() throws {
        let json = """
        {
          "seven_day": {"utilization": 5.0, "resets_at": "2026-04-28T19:00:00Z"},
          "extra_usage": {
            "is_enabled": true,
            "monthly_limit": 2000,
            "used_credits": 250.0,
            "utilization": 12.5,
            "currency": "EUR",
            "overage_balance": 875.0,
            "overage_balance_currency": "eur"
          }
        }
        """.data(using: .utf8)!

        let usage = try ClaudeAPIClient.parseUsageResponse(data: json)

        #expect(usage.extraUsage?.currency == "EUR")
        #expect(usage.extraUsage?.overageBalance == 875.0)
        #expect(usage.extraUsage?.overageBalanceCurrency == "eur")
    }

    @Test func decodePercentageScaleResponse() throws {
        let json = """
        {
          "five_hour": { "utilization": 5.0, "resets_at": "2026-04-12T15:30:00.000Z" },
          "seven_day": { "utilization": 15.0, "resets_at": "2026-04-14T12:59:00.000Z" }
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601

        let usage = try decoder.decode(UsageResponse.self, from: json)

        #expect(abs(usage.fiveHour!.utilization - 0.05) < 0.001)
        #expect(abs(usage.sevenDay.utilization - 0.15) < 0.001)
    }

    @Test func subscriptionTierFromRateLimitTier() {
        #expect(SubscriptionTier.from(rateLimitTier: "default_claude_pro", capabilities: nil) == .pro)
        #expect(SubscriptionTier.from(rateLimitTier: "default_claude_max_5x", capabilities: nil) == .max5x)
        #expect(SubscriptionTier.from(rateLimitTier: "default_claude_max_20x", capabilities: nil) == .max20x)
        #expect(SubscriptionTier.from(rateLimitTier: "default_claude_team", capabilities: nil) == .team)
        #expect(SubscriptionTier.from(rateLimitTier: "some_future_tier", capabilities: nil) == .unknown("tier"))
        #expect(SubscriptionTier.from(rateLimitTier: "default_claude_ai", capabilities: nil) == .pro)
        #expect(SubscriptionTier.from(rateLimitTier: "default_raven", capabilities: nil) == .team)
        #expect(SubscriptionTier.from(rateLimitTier: "default_raven", capabilities: ["claude_team"]) == .team)
        #expect(SubscriptionTier.from(rateLimitTier: "default_raven", capabilities: ["claude_enterprise"]) == .enterprise)
    }

    @Test func subscriptionTierFallsBackToCapabilities() {
        // No rate_limit_tier — use capabilities as a safety net.
        #expect(SubscriptionTier.from(rateLimitTier: nil, capabilities: ["claude_max", "chat"]) == .max5x)
        #expect(SubscriptionTier.from(rateLimitTier: nil, capabilities: ["claude_pro"]) == .pro)
        #expect(SubscriptionTier.from(rateLimitTier: nil, capabilities: []) == .unknown(nil))
        #expect(SubscriptionTier.from(rateLimitTier: nil, capabilities: ["claude_enterprise"]) == .enterprise)
        #expect(SubscriptionTier.from(rateLimitTier: nil, capabilities: ["raven"]) == .team)
        #expect(SubscriptionTier.from(rateLimitTier: nil, capabilities: ["claude_team"]) == .team)
    }

    @Test func enterpriseTierLocalizationKey() {
        #expect(SubscriptionTier.enterprise.localizationKey == "tier.enterprise")
    }

    @Test func decodeOrganizationDetails() throws {
        // Truncated version of the real /organizations/{id} response.
        let json = """
        {
          "uuid": "4f4dee87-d910-4390-ae54-b64ad23b9243",
          "name": "babin@axveer.com's Organization",
          "capabilities": ["claude_max", "chat"],
          "rate_limit_tier": "default_claude_max_5x",
          "api_disabled_reason": null,
          "api_disabled_until": null,
          "billable_usage_paused_until": null
        }
        """.data(using: .utf8)!

        let details = try ClaudeAPIClient.parseOrganizationDetailsResponse(data: json)

        #expect(details.uuid == "4f4dee87-d910-4390-ae54-b64ad23b9243")
        #expect(details.rateLimitTier == "default_claude_max_5x")
        #expect(details.tier == .max5x)
        #expect(details.capabilities?.contains("claude_max") == true)
        #expect(details.apiDisabledUntil == nil)
    }

    @Test func colorForUtilization() {
        #expect(UsageColor.forUtilization(0.0) == .green)
        #expect(UsageColor.forUtilization(0.3) == .green)
        #expect(UsageColor.forUtilization(0.5) == .green)
        #expect(UsageColor.forUtilization(0.51) == .yellow)
        #expect(UsageColor.forUtilization(0.75) == .yellow)
        #expect(UsageColor.forUtilization(0.76) == .orange)
        #expect(UsageColor.forUtilization(0.9) == .orange)
        #expect(UsageColor.forUtilization(0.91) == .red)
        #expect(UsageColor.forUtilization(1.0) == .red)
    }

    @Test func decodePlatformCreditsResponse() throws {
        let json = """
        {
          "amount": 189,
          "currency": "USD",
          "auto_reload_settings": null,
          "pending_invoice_amount_cents": null,
          "last_paid_purchase_cents": null
        }
        """.data(using: .utf8)!

        let credits = try JSONDecoder().decode(PlatformCredits.self, from: json)

        #expect(credits.amountCents == 189)
        #expect(credits.currency == "USD")
        #expect(abs(credits.amount - 1.89) < 0.0001)
    }

    @Test func decodePlatformCreditsZeroBalance() throws {
        let json = #"{ "amount": 0, "currency": "USD" }"#.data(using: .utf8)!
        let credits = try JSONDecoder().decode(PlatformCredits.self, from: json)
        #expect(credits.amountCents == 0)
        #expect(credits.amount == 0.0)
    }

    @Test func platformCreditsFormattedUSEnglish() {
        let credits = PlatformCredits(amountCents: 189, currency: "USD")
        let formatted = credits.formatted(locale: Locale(identifier: "en_US"))
        #expect(formatted.contains("1.89"))
        #expect(formatted.contains("$"))
    }

    @Test func platformCreditsFormattedLargeAmount() {
        let credits = PlatformCredits(amountCents: 1_234_567, currency: "USD")
        let formatted = credits.formatted(locale: Locale(identifier: "en_US"))
        #expect(formatted.contains("12,345.67"))
    }
}
