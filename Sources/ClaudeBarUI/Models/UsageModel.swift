import SwiftUI

// MARK: - API Response Models

public struct UsageResponse: Codable {
    public let fiveHour: WindowUsage?
    public let sevenDay: WindowUsage
    public let extraUsage: ExtraUsage?
    /// Every other window-shaped field the API returns (per-model windows and
    /// codenamed credit pools), excluding the structured fields above. Decoded
    /// generically so Anthropic's frequent reshuffles surface automatically
    /// instead of silently disappearing. Only non-null windows are kept.
    public let additionalWindows: [AdditionalWindow]

    /// Backward-compatible typed accessors. The per-model windows now live in
    /// `additionalWindows`; these look them up by their (camelCased) API key.
    public var sevenDaySonnet: WindowUsage? { typedWindow("sevenDaySonnet") }
    public var sevenDayOpus: WindowUsage? { typedWindow("sevenDayOpus") }
    public var sevenDayOmelette: WindowUsage? { typedWindow("sevenDayOmelette") }

    private func typedWindow(_ key: String) -> WindowUsage? {
        additionalWindows.first { $0.key == key }
            .map { WindowUsage(utilization: $0.utilization, resetsAt: $0.resetsAt) }
    }

    public init(
        fiveHour: WindowUsage?,
        sevenDay: WindowUsage,
        sevenDaySonnet: WindowUsage? = nil,
        sevenDayOpus: WindowUsage? = nil,
        sevenDayOmelette: WindowUsage? = nil,
        additionalWindows: [AdditionalWindow] = [],
        extraUsage: ExtraUsage? = nil
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.extraUsage = extraUsage
        var windows = additionalWindows
        // Fold the legacy convenience params into the generic collection so
        // existing call sites (tests, #Preview) keep working unchanged.
        if let s = sevenDaySonnet { windows.append(AdditionalWindow(key: "sevenDaySonnet", utilization: s.utilization, resetsAt: s.resetsAt)) }
        if let o = sevenDayOpus { windows.append(AdditionalWindow(key: "sevenDayOpus", utilization: o.utilization, resetsAt: o.resetsAt)) }
        if let d = sevenDayOmelette { windows.append(AdditionalWindow(key: "sevenDayOmelette", utilization: d.utilization, resetsAt: d.resetsAt)) }
        self.additionalWindows = AdditionalWindow.sorted(windows)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.fiveHour = try container.decodeIfPresent(WindowUsage.self, forKey: DynamicCodingKey("fiveHour"))
        self.sevenDay = try container.decode(WindowUsage.self, forKey: DynamicCodingKey("sevenDay"))
        self.extraUsage = try container.decodeIfPresent(ExtraUsage.self, forKey: DynamicCodingKey("extraUsage"))

        // Keys arrive camelCased (decoder uses `.convertFromSnakeCase`).
        let structured: Set<String> = ["fiveHour", "sevenDay", "extraUsage", "limits", "spend"]
        var windows: [AdditionalWindow] = []
        for key in container.allKeys where !structured.contains(key.stringValue) {
            if (try? container.decodeNil(forKey: key)) == true { continue }
            guard let raw = try? container.decode(AdditionalWindow.RawWindow.self, forKey: key) else { continue }
            windows.append(AdditionalWindow(
                key: key.stringValue,
                utilization: raw.utilization,
                resetsAt: raw.resetsAt,
                limitDollars: raw.limitDollars,
                usedDollars: raw.usedDollars,
                remainingDollars: raw.remainingDollars
            ))
        }

        // As of 2026-07 the per-model `seven_day_*` windows are retired; the
        // model-specific weekly limit now lives in the `limits` array as a
        // `weekly_scoped` entry whose `scope.model.display_name` names the model
        // (e.g. "Fable"). Surface those as per-model windows so they render like
        // the old Sonnet/Opus rows — driven by the API's own display name, never
        // a hardcoded codename guess.
        let limits = (try? container.decode([UsageLimit].self, forKey: DynamicCodingKey("limits"))) ?? []
        for limit in limits where limit.kind == "weekly_scoped" {
            guard let name = limit.scope?.model?.displayName, !name.isEmpty else { continue }
            windows.append(AdditionalWindow(
                key: Self.modelWindowKey(name),
                utilization: limit.percent / 100.0,
                resetsAt: limit.resetsAt,
                explicitLabel: name,
                isModelScoped: true
            ))
        }
        self.additionalWindows = AdditionalWindow.sorted(windows)
    }

    /// Synthesizes a stable, `sevenDay`-prefixed key from an API model display
    /// name so model-scoped windows slot into the existing naming convention
    /// (`"Fable"` → `"sevenDayFable"`).
    static func modelWindowKey(_ displayName: String) -> String {
        let alnum = displayName.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return "sevenDay" + String(String.UnicodeScalarView(alnum))
    }

    enum CodingKeys: String, CodingKey {
        case fiveHour, sevenDay, extraUsage, additionalWindows
    }

    /// Max plans get an `extra_usage` credit pool; Pro plans don't. Cleanest
    /// tier signal from `/usage` — independent of per-model window reshuffles.
    public var isMaxTier: Bool {
        guard let extra = extraUsage, extra.isEnabled else { return false }
        return (extra.monthlyLimit ?? 0) > 0
    }
}

/// One entry of the `/usage` `limits` array. The API groups rate limits here
/// by `kind` (`session`, `weekly_all`, `weekly_scoped`); the `weekly_scoped`
/// ones carry a `scope.model.display_name` naming the model they apply to.
public struct UsageLimit: Decodable {
    public let kind: String
    public let percent: Double
    public let resetsAt: Date?
    public let isActive: Bool?
    public let scope: Scope?

    public struct Scope: Decodable {
        public let model: Model?
    }
    public struct Model: Decodable {
        public let id: String?
        public let displayName: String?
    }
}

/// A `/usage` window the app doesn't model statically — a per-model rolling
/// window (Sonnet/Opus/Design), a codenamed credit pool (e.g. `amber_ladder`),
/// or a model-scoped weekly limit synthesized from the `limits` array (e.g.
/// "Fable", carrying an `explicitLabel`). Anthropic adds and retires these
/// often, so we decode whatever is present and resolve a display label rather
/// than hardcoding each one.
public struct AdditionalWindow: Codable, Equatable, Identifiable {
    /// The camelCased API key, e.g. `sevenDaySonnet` or `amberLadder`.
    public let key: String
    /// Utilization as a fraction (0.0–1.0).
    public let utilization: Double
    public let resetsAt: Date?
    /// Dollar-denominated pools (credit grants) carry these; per-model windows don't.
    public let limitDollars: Double?
    public let usedDollars: Double?
    public let remainingDollars: Double?
    /// A label the API handed us verbatim (e.g. the `scope.model.display_name`
    /// of a `weekly_scoped` limit — "Fable"). When present it wins over any
    /// derived name, because the API is stating the real model name itself.
    public let explicitLabel: String?
    /// True for windows synthesized from a `weekly_scoped` model limit (as
    /// opposed to top-level window-shaped keys / codenamed dollar pools).
    public let isModelScoped: Bool

    public var id: String { key }
    public var isDollarPool: Bool { limitDollars != nil }

    public init(
        key: String,
        utilization: Double,
        resetsAt: Date?,
        limitDollars: Double? = nil,
        usedDollars: Double? = nil,
        remainingDollars: Double? = nil,
        explicitLabel: String? = nil,
        isModelScoped: Bool = false
    ) {
        self.key = key
        self.utilization = utilization
        self.resetsAt = resetsAt
        self.limitDollars = limitDollars
        self.usedDollars = usedDollars
        self.remainingDollars = remainingDollars
        self.explicitLabel = explicitLabel
        self.isModelScoped = isModelScoped
    }

    /// Friendly label: the API-provided label if any, else a curated name for
    /// known codenames, else a Title-Cased humanization of the raw key
    /// (`amberLadder` → "Amber Ladder").
    public var displayName: String { explicitLabel ?? Self.friendlyNames[key] ?? Self.humanize(key) }

    // Only add a key here once Anthropic has a *confirmed* public meaning for it.
    // The `/usage` endpoint also ships auto-generated `adjective_noun` codenames
    // (e.g. `amber_ladder`, `cinder_cove`, `iguana_necktie`, `tangelo`) as slots
    // for unlaunched/unnamed rate-limit & credit buckets — almost always null.
    // As of 2026-07, no public source (docs, news, or the leaked claudeAiLimits.ts
    // source map) names any of these slots, so we do NOT hardcode a guess here.
    // Instead, the view keys off confirmed *structure*: a window with limit_dollars
    // (e.g. `amber_ladder`, seen live 2026-06 as a $2500 ~quarterly Team pool) is a
    // usage-credit pool regardless of codename, and renders as "Usage Credits".
    // Non-dollar unknown codenames fall through to humanize() below.
    static let friendlyNames: [String: String] = [
        "sevenDaySonnet": "Sonnet",
        "sevenDayOpus": "Opus",
        "sevenDayOmelette": "Design",
        "sevenDayCowork": "Cowork",
        "sevenDayOauthApps": "Connected Apps",
    ]

    /// Stable ordering: known per-model windows first (Sonnet, Opus, Design, …),
    /// then everything else alphabetically by display name.
    static func sorted(_ windows: [AdditionalWindow]) -> [AdditionalWindow] {
        let priority = ["sevenDaySonnet", "sevenDayOpus", "sevenDayOmelette", "sevenDayCowork", "sevenDayOauthApps"]
        // Known per-model windows first, then API model-scoped windows (Fable, …),
        // then everything else (codenamed pools) alphabetically by display name.
        func rank(_ w: AdditionalWindow) -> Int {
            if let i = priority.firstIndex(of: w.key) { return i }
            return w.isModelScoped ? priority.count : priority.count + 1
        }
        return windows.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            return ra != rb ? ra < rb : a.displayName < b.displayName
        }
    }

    /// Turns a camelCase key into spaced Title Case, dropping a leading
    /// `sevenDay` prefix (`sevenDayFoo` → "Foo", `amberLadder` → "Amber Ladder").
    static func humanize(_ camel: String) -> String {
        var rest = Substring(camel)
        if rest.hasPrefix("sevenDay") { rest = rest.dropFirst("sevenDay".count) }
        var words: [String] = []
        var current = ""
        for ch in rest {
            if ch.isUppercase && !current.isEmpty {
                words.append(current)
                current = String(ch)
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// Decodes the raw window object; `utilization` is normalized 0–100 → 0.0–1.0
    /// to match `WindowUsage`. Used only via `UsageResponse`'s dynamic decoder.
    struct RawWindow: Decodable {
        let utilization: Double
        let resetsAt: Date?
        let limitDollars: Double?
        let usedDollars: Double?
        let remainingDollars: Double?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.utilization = (try c.decode(Double.self, forKey: .utilization)) / 100.0
            self.resetsAt = try c.decodeIfPresent(Date.self, forKey: .resetsAt)
            self.limitDollars = try c.decodeIfPresent(Double.self, forKey: .limitDollars)
            self.usedDollars = try c.decodeIfPresent(Double.self, forKey: .usedDollars)
            self.remainingDollars = try c.decodeIfPresent(Double.self, forKey: .remainingDollars)
        }

        enum CodingKeys: String, CodingKey {
            case utilization, resetsAt, limitDollars, usedDollars, remainingDollars
        }
    }
}

/// String-only coding key for decoding objects with dynamic/unknown field names.
struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
    init(_ string: String) { self.stringValue = string }
}

public struct WindowUsage: Codable {
    /// Utilization as a fraction (0.0 to 1.0). The API returns 0–100; the decoder divides by 100.
    public let utilization: Double
    public let resetsAt: Date?

    public init(utilization: Double, resetsAt: Date?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawUtilization = try container.decode(Double.self, forKey: .utilization)
        self.utilization = rawUtilization / 100.0
        self.resetsAt = try container.decodeIfPresent(Date.self, forKey: .resetsAt)
    }
}

public struct ExtraUsage: Codable {
    public let isEnabled: Bool
    public let monthlyLimit: Double?
    public let usedCredits: Double?
    public let utilization: Double?
    public let currency: String?
    public let overageBalance: Double?
    public let overageBalanceCurrency: String?

    public init(
        isEnabled: Bool,
        monthlyLimit: Double?,
        usedCredits: Double?,
        utilization: Double?,
        currency: String? = nil,
        overageBalance: Double? = nil,
        overageBalanceCurrency: String? = nil
    ) {
        self.isEnabled = isEnabled
        self.monthlyLimit = monthlyLimit
        self.usedCredits = usedCredits
        self.utilization = utilization
        self.currency = currency
        self.overageBalance = overageBalance
        self.overageBalanceCurrency = overageBalanceCurrency
    }
}

public struct Organization: Codable, Equatable {
    public let uuid: String
    public let name: String
    public let capabilities: [String]?

    public init(uuid: String, name: String, capabilities: [String]? = nil) {
        self.uuid = uuid
        self.name = name
        self.capabilities = capabilities
    }

    /// Strips the default `'s Organization` suffix Claude.ai assigns to
    /// personal orgs (e.g. `Vladimir's Organization` → `Vladimir`).
    public var displayName: String {
        let suffix = "'s Organization"
        if name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    /// True when the org has at least one paid-plan capability marker.
    /// Used to hide free/individual orgs from the switcher UI — they
    /// have no usage worth tracking in the menu bar.
    public var isPaidPlan: Bool {
        guard let caps = capabilities else { return false }
        let paidMarkers: Set<String> = [
            "claude_pro", "claude_max", "claude_max_5x", "claude_max_20x",
            "claude_team", "claude_enterprise", "raven",
        ]
        return caps.contains(where: paidMarkers.contains)
    }
}

public struct OrganizationDetails: Codable {
    public let uuid: String
    public let name: String
    public let rateLimitTier: String?
    public let capabilities: [String]?
    public let apiDisabledUntil: Date?
    public let billableUsagePausedUntil: Date?

    public init(
        uuid: String,
        name: String,
        rateLimitTier: String?,
        capabilities: [String]? = nil,
        apiDisabledUntil: Date? = nil,
        billableUsagePausedUntil: Date? = nil
    ) {
        self.uuid = uuid
        self.name = name
        self.rateLimitTier = rateLimitTier
        self.capabilities = capabilities
        self.apiDisabledUntil = apiDisabledUntil
        self.billableUsagePausedUntil = billableUsagePausedUntil
    }

    public var tier: SubscriptionTier { .from(rateLimitTier: rateLimitTier, capabilities: capabilities) }
}

public struct PlatformCredits: Codable, Equatable {
    public let amountCents: Int
    public let currency: String

    enum CodingKeys: String, CodingKey {
        case amountCents = "amount"
        case currency
    }

    public init(amountCents: Int, currency: String) {
        self.amountCents = amountCents
        self.currency = currency
    }

    public var amount: Double { Double(amountCents) / 100.0 }

    public func formatted(locale: Locale = .current) -> String {
        let decimal = Decimal(amountCents) / 100
        return decimal.formatted(.currency(code: currency).locale(locale))
    }
}

public enum SubscriptionTier: Equatable {
    case pro
    case max5x
    case max20x
    case team
    case enterprise
    case unknown(String?)

    /// Parse from Claude.ai's `rate_limit_tier` (e.g. `default_claude_max_5x`).
    /// Falls back to `capabilities` when the tier string is missing.
    public static func from(rateLimitTier: String?, capabilities: [String]?) -> SubscriptionTier {
        switch rateLimitTier {
        case "default_claude_pro", "default_claude_ai":
            return .pro
        case "default_claude_max_5x": return .max5x
        case "default_claude_max_20x": return .max20x
        case "default_claude_team": return .team
        case "default_raven":
            if capabilities?.contains("claude_enterprise") == true { return .enterprise }
            return .team
        case let other?:
            // Unknown explicit tier — preserve raw suffix for debugging.
            if let raw = other.split(separator: "_").last.map(String.init) {
                return .unknown(raw)
            }
            return .unknown(other)
        case nil:
            // No rate_limit_tier — infer from capabilities as a last resort.
            if let caps = capabilities {
                if caps.contains("claude_enterprise") { return .enterprise }
                if caps.contains("claude_max")        { return .max5x }
                if caps.contains("claude_team") ||
                   caps.contains("raven")             { return .team }
                if caps.contains("claude_pro")        { return .pro }
            }
            return .unknown(nil)
        }
    }

    public var localizationKey: String {
        switch self {
        case .pro: return "tier.pro"
        case .max5x: return "tier.max5x"
        case .max20x: return "tier.max20x"
        case .team: return "tier.team"
        case .enterprise: return "tier.enterprise"
        case .unknown: return "tier.unknown"
        }
    }
}

// MARK: - Display Helpers

public enum UsageColor {
    case green, yellow, orange, red

    public static func forUtilization(_ value: Double) -> UsageColor {
        switch value {
        case ..<0.51: return .green
        case ..<0.76: return .yellow
        case ..<0.91: return .orange
        default: return .red
        }
    }

    public var swiftUIColor: Color {
        switch self {
        case .green: return Color(red: 0.29, green: 0.87, blue: 0.50)   // #4ade80
        case .yellow: return Color(red: 0.98, green: 0.80, blue: 0.08)  // #facc15
        case .orange: return Color(red: 0.83, green: 0.65, blue: 0.46)  // #D4A574
        case .red: return Color(red: 0.94, green: 0.27, blue: 0.27)     // #ef4444
        }
    }
}
