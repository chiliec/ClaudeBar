import Foundation

/// Static configuration for ClaudeBar Pro.
///
/// The checkout URL is the Lemon Squeezy "buy" link for the Pro variant
/// (Dashboard → Product → Share → Buy link). Fill it in once the LS product
/// exists; the in-app "Upgrade to Pro" button opens it.
public enum ProConfig {
    /// Lemon Squeezy checkout URL for the one-time Pro purchase.
    /// TODO: replace with the real variant buy link, e.g.
    /// https://claudebar.lemonsqueezy.com/buy/<variant-uuid>
    public static let checkoutURLString = "https://claudebar.lemonsqueezy.com/buy/REPLACE_ME"

    public static var checkoutURL: URL? { URL(string: checkoutURLString) }

    /// One-time price shown in the upgrade UI (display only; LS is the source of truth).
    public static let priceDisplay = "$9.99"

    /// The Pro-only capabilities. Gate NEW features only — everything already in
    /// the free build (menu-bar indicator, 5-hour + 7-day bars, tier detection,
    /// auto-refresh, single-account) stays free forever.
    public enum Feature: String, CaseIterable {
        case usageHistory        // history + graphs over time
        case multiAccount        // more than one Claude account
        case spendAlerts         // threshold notifications
        case platformCreditAlert // platform.claude.com prepaid-credit low alert
        case csvExport           // export usage history

        public var title: String {
            switch self {
            case .usageHistory: return "Usage history & graphs"
            case .multiAccount: return "Multiple accounts"
            case .spendAlerts: return "Usage & spend alerts"
            case .platformCreditAlert: return "Low-credit alerts"
            case .csvExport: return "CSV export"
            }
        }
    }
}
