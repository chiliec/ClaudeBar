import SwiftUI

struct UsageDetailView: View {
    let state: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            if let usage = state.usage {
                fiveHourSection(usage)
                Divider()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                sevenDaySection(usage)
                if let extra = usage.extraUsage, extra.isEnabled,
                   let used = extra.usedCredits, let limit = extra.monthlyLimit, limit > 0 {
                    Divider()
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                    extraUsageSection(used: used, limit: limit, currency: extra.currency, overage: extra.overageBalance, overageCurrency: extra.overageBalanceCurrency)
                }
                if let credits = state.platformCredits {
                    Divider()
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                    apiCreditsSection(credits, isStale: state.platformCreditsIsStale)
                }
            } else if state.isLoading {
                ProgressView()
                    .padding(40)
            } else if let error = state.error {
                Text(error.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(20)
            } else {
                Text("usage.noData", bundle: .module)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .padding(40)
            }
            footer
        }
    }

    private var header: some View {
        HStack {
            headerTitle
            Spacer()
            if let details = state.organizationDetails {
                tierPill(for: details.tier)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func tierPill(for tier: SubscriptionTier) -> some View {
        let label = Group {
            if case .unknown(let raw?) = tier {
                Text(verbatim: raw.capitalized)
            } else {
                Text(LocalizedStringKey(tier.localizationKey), bundle: .module)
            }
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)

        if #available(macOS 26.0, *) {
            label.glassEffect()
        } else {
            label.background(.quaternary).clipShape(Capsule())
        }
    }

    @ViewBuilder
    private var headerTitle: some View {
        let title = state.organizationDetails?.name
            ?? state.accounts.first { $0.id == state.activeID }?.label
        Menu {
            ForEach(state.accounts) { account in
                Button {
                    state.switchTo(id: account.id)
                } label: {
                    if account.id == state.activeID {
                        Label(account.label, systemImage: "checkmark")
                    } else {
                        Text(account.label)
                    }
                }
            }
            if !state.accounts.isEmpty { Divider() }
            Button {
                Task { await state.signIn() }
            } label: {
                Text("action.addAccount", bundle: .module)
            }
        } label: {
            HStack(spacing: 4) {
                Text(title ?? String(localized: "usage.title", bundle: .module))
                    .font(.headline)
                if state.accounts.count > 1 {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func fiveHourSection(_ usage: UsageResponse) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            let utilization = usage.fiveHour?.utilization ?? 0
            let color = UsageColor.forUtilization(utilization).swiftUIColor

            HStack {
                Text("usage.fiveHourWindow", bundle: .module)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if let reset = usage.fiveHour?.resetsAt {
                    Text("usage.resetsIn \(ResetDuration.string(from: reset))", bundle: .module)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel(ResetDuration.accessibilityLabel(for: reset))
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary)
                    if utilization > 0 {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(color)
                            .frame(width: max(geo.size.width * utilization, 8))
                            .animation(.easeInOut(duration: 0.4), value: utilization)
                    }
                    Text(verbatim: "\(Int(utilization * 100))%")
                        .font(.subheadline.bold())
                        .bold()
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .frame(height: 20)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func sevenDaySection(_ usage: UsageResponse) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("usage.sevenDayWindows", bundle: .module)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            slimBar(label: String(localized: "usage.total", bundle: .module), utilization: usage.sevenDay.utilization, resetDate: usage.sevenDay.resetsAt, color: .blue)

            // Per-model windows and codenamed credit pools are decoded generically
            // (see `UsageResponse.additionalWindows`). We render whatever the API
            // currently reports as non-null — `null` means "not provisioned", not
            // "0% used", so those rows simply don't appear. This auto-tracks
            // Anthropic's frequent window reshuffles without code changes.
            ForEach(Array(usage.additionalWindows.enumerated()), id: \.element.id) { index, window in
                slimBar(
                    label: Self.windowLabel(window),
                    utilization: window.utilization,
                    resetDate: window.resetsAt,
                    color: Self.windowColor(window, index: index),
                    detail: Self.dollarDetail(window)
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func slimBar(label: String, utilization: Double, resetDate: Date?, color: Color, detail: String? = nil) -> some View {
        VStack(spacing: 3) {
            HStack {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if let detail {
                    (Text(verbatim: detail) + Text(verbatim: " ·"))
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
                if let date = resetDate {
                    (Text("usage.resetsIn \(ResetDuration.string(from: date))", bundle: .module) + Text(verbatim: " ·"))
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel(ResetDuration.accessibilityLabel(for: date))
                }
                Text(verbatim: "\(Int(utilization * 100))%")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary)
                    if utilization > 0 {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(color)
                            .frame(width: max(geo.size.width * utilization, 6))
                            .animation(.easeInOut(duration: 0.4), value: utilization)
                    }
                }
            }
            .frame(height: 8)
        }
    }

    private func extraUsageSection(used: Double, limit: Double, currency: String?, overage: Double?, overageCurrency: String?) -> some View {
        let currencySymbol = Self.currencySymbol(for: currency)
        let usedDisplay = "\(currencySymbol)\(String(format: "%.2f", used / 100))"
        let limitDisplay = "\(currencySymbol)\(String(format: "%.0f", limit / 100))"
        return VStack(alignment: .leading, spacing: 6) {
            Text("usage.extraCredits", bundle: .module)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            slimBar(
                label: String(localized: "usage.creditsUsed \(usedDisplay) \(limitDisplay)", bundle: .module),
                utilization: min(used / limit, 1.0),
                resetDate: nil,
                color: .teal
            )

            if let overage, let overageCurrency {
                let overageSymbol = Self.currencySymbol(for: overageCurrency)
                HStack {
                    Text("usage.overageBalance", bundle: .module)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(verbatim: "\(overageSymbol)\(String(format: "%.2f", overage / 100))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func apiCreditsSection(_ credits: PlatformCredits, isStale: Bool) -> some View {
        HStack {
            Text("section.apiCredits", bundle: .module)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(verbatim: credits.formatted())
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .opacity(isStale ? 0.5 : 1.0)
    }

    private static func currencySymbol(for code: String?) -> String {
        switch code?.uppercased() {
        case nil, "USD": return "$"
        case "EUR": return "€"
        case "GBP": return "£"
        case "JPY": return "¥"
        case let other?: return "\(other) "
        }
    }

    // MARK: - Generic window presentation

    /// Localized label for the windows we ship translations for; the generic
    /// (Title-Cased) `displayName` for everything else.
    static func windowLabel(_ window: AdditionalWindow) -> String {
        switch window.key {
        case "sevenDaySonnet": return String(localized: "usage.sonnet", bundle: .module)
        case "sevenDayOpus": return String(localized: "usage.opus", bundle: .module)
        case "sevenDayOmelette": return String(localized: "usage.design", bundle: .module)
        default:
            if window.isDollarPool {
                return String(localized: "usage.usageCredits", bundle: .module)
            }
            return window.displayName
        }
    }

    /// Curated colors for the established per-model windows; a cycled palette
    /// keeps newly-surfaced codenamed windows visually distinct.
    static func windowColor(_ window: AdditionalWindow, index: Int) -> Color {
        switch window.key {
        case "sevenDaySonnet": return Color(red: 0.38, green: 0.65, blue: 0.98)   // blue
        case "sevenDayOpus": return Color(red: 0.65, green: 0.55, blue: 0.98)      // purple
        case "sevenDayOmelette": return Color(red: 0.95, green: 0.60, blue: 0.40)  // orange
        default: return windowPalette[index % windowPalette.count]
        }
    }

    private static let windowPalette: [Color] = [
        Color(red: 0.40, green: 0.80, blue: 0.75),  // teal
        Color(red: 0.85, green: 0.55, blue: 0.75),  // pink
        Color(red: 0.60, green: 0.75, blue: 0.45),  // green
        Color(red: 0.90, green: 0.75, blue: 0.40),  // amber
    ]

    /// For dollar-denominated pools (credit grants), the "$used / $limit" string
    /// shown alongside the utilization bar. `nil` for plain per-model windows.
    static func dollarDetail(_ window: AdditionalWindow) -> String? {
        guard let limit = window.limitDollars else { return nil }
        return "\(money(window.usedDollars ?? 0)) / \(money(limit))"
    }

    private static func money(_ value: Double) -> String {
        if value == value.rounded() {
            return "$" + Int(value).formatted(.number.grouping(.automatic))
        }
        return "$" + value.formatted(.number.precision(.fractionLength(2)).grouping(.automatic))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let lastUpdated = state.lastUpdated {
                Text("usage.updatedAgo \(lastUpdated, style: .relative)", bundle: .module)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            if state.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            } else {
                Button {
                    Task { await state.refreshUsage() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.body)
                }
                .modifier(FooterButtonModifier())
                .help(String(localized: "action.refresh", bundle: .module))
            }
            Button {
                state.showingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.body)
            }
            .modifier(FooterButtonModifier())
            .help(String(localized: "settings.title", bundle: .module))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

}

// MARK: - Liquid Glass Modifiers

private struct FooterButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .foregroundStyle(.blue)
                .buttonStyle(.glass)
        } else {
            content
                .foregroundStyle(.blue)
                .buttonStyle(.plain)
        }
    }
}
