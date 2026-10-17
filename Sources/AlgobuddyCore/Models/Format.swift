import Foundation

/// How figures and labels are written, in the panel and in the menu bar.
public enum Format {
    /// Stand-in for a value the reader has chosen not to display. Bullets keep
    /// a row looking like a row, where a word such as "hidden" would read as a
    /// status and invite the question of what went wrong.
    public static func hidden(_ length: Int = 6) -> String {
        String(repeating: "•", count: length)
    }

    /// The panel's ALGO amount, or its mask: the one place the two compose, so
    /// every money surface masks identically. The menu bar builds its own
    /// narrower form because its width budget is different, deliberately.
    public static func algosLabel(_ amount: MicroAlgos, hidden: Bool) -> String {
        hidden ? "\(Self.hidden()) ALGO" : "\(algos(amount, decimals: 2)) ALGO"
    }

    /// An amount where a row has little room for it: in millions from ten
    /// million on, so no row's amount is wider than `widestRowAmount`. The
    /// account's own page shows it in full.
    public static func rowAlgosLabel(_ amount: MicroAlgos, hidden: Bool) -> String {
        guard !hidden, amount.algos >= 10_000_000 else { return algosLabel(amount, hidden: hidden) }
        return String(format: "%.2fM ALGO", amount.algos / 1_000_000)
    }

    /// The widest amount `rowAlgosLabel` gives, in digits of one width.
    public static let widestRowAmount = "0000000.00 ALGO"

    /// A shortened address, or its mask, on the same terms as `algosLabel`.
    /// Every surface that shows an address goes through here, by itself or
    /// through `accountLabel`, so a new one cannot show a real address while
    /// values are hidden.
    public static func addressLabel(_ value: String, hidden: Bool) -> String {
        hidden ? Self.hidden() : address(value)
    }

    /// What an account goes by: the name the user gave it, otherwise its short
    /// address or that address's mask. A name is never masked. It is the
    /// user's own label, and what tells the accounts apart while their
    /// addresses are hidden.
    public static func accountLabel(
        _ address: AlgorandAddress, names: AccountNames, hidden: Bool
    ) -> String {
        names.label(for: address, otherwise: addressLabel(address.stringValue, hidden: hidden))
    }

    /// Compact, and steady: above a million it changes once in 10,000 rounds.
    /// The full round changes every few seconds, and in the menu bar's
    /// proportional digits each change would shove everything to its left
    /// around.
    public static func round(_ value: UInt64) -> String {
        if value >= 1_000_000 {
            return String(format: "%.2fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000)
        }
        return "\(value)"
    }

    /// A round in full, as `goal` prints it, where the menu bar's compact form
    /// would round it off. Without the locale's grouping, which in some
    /// locales is a dot and would read as a decimal beside the amounts.
    public static func exactRound(_ value: UInt64) -> String { "\(value)" }

    public static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "-" }
        if seconds <= 0 { return "overdue" }
        let days = seconds / 86_400
        if days >= 1 { return String(format: "%.1fd", days) }
        let hours = seconds / 3_600
        if hours >= 1 { return String(format: "%.1fh", hours) }
        return String(format: "%.0fm", max(1, seconds / 60))
    }

    public static func algos(_ amount: MicroAlgos, decimals: Int = 2) -> String {
        String(format: "%.\(decimals)f", amount.algos)
    }

    public static func relative(_ seconds: TimeInterval) -> String {
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(Int(seconds))s ago" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m ago" }
        // Days matter: a small staker's expected proposal gap runs to days, so
        // without this branch a healthy account reads "156h ago".
        if seconds < 48 * 3_600 { return "\(Int(seconds / 3_600))h ago" }
        return String(format: "%.1fd ago", seconds / 86_400)
    }

    public static func address(_ value: String) -> String {
        guard value.count > 16 else { return value }
        return "\(value.prefix(6))…\(value.suffix(6))"
    }
}
