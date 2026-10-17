import AlgobuddyCore
import SwiftUI

/// Overall state, derived from the worst alert currently holding.
enum HealthLevel: Int, Comparable {
    case unknown, ok, warning, critical

    static func < (lhs: HealthLevel, rhs: HealthLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Distinct **shapes**, not just distinct colours.
    ///
    /// The menu bar item is a template image, drawn by `MenuBarImage`, so it
    /// takes the menu bar's own colour and shows no tint. The symbol therefore
    /// has to carry the whole signal, which is also what makes it readable to
    /// anyone who cannot distinguish the colours. The tint below applies in the
    /// panel's account rows, which are not templated.
    var symbol: String {
        switch self {
        case .unknown: "circle.dotted"
        case .ok: "circle.fill"
        case .warning: "triangle.fill"
        case .critical: "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .unknown: .secondary
        case .ok: .green
        case .warning: .orange
        case .critical: .red
        }
    }

    var label: String {
        switch self {
        case .unknown: "No data"
        case .ok: "Healthy"
        case .warning: "Attention"
        case .critical: "Critical"
        }
    }

    /// The one severity-to-health mapping, so the icon can never grade a
    /// severity differently from the alert list it summarises. Quiet maps to
    /// healthy only when there is data to be healthy about.
    init(worstOf severities: [AlertSeverity], hasData: Bool) {
        switch severities.max() {
        case .critical: self = .critical
        case .warning: self = .warning
        default: self = hasData ? .ok : .unknown
        }
    }
}

/// Two sizes, and that is the whole scale.
///
/// HIG: "Minimize the number of typefaces you use … Mixing too many different
/// typefaces can obscure your information hierarchy and hinder readability, in
/// addition to making an interface feel internally inconsistent or poorly
/// designed."
///
/// Hierarchy comes from weight and colour instead, which is what the guidelines
/// recommend: "Adjust font weight, size, and color as needed to emphasize
/// important information."
///
/// 13 pt is the macOS default and 10 pt the documented minimum.
enum Typography {
    /// The real system menu font, so panel rows match native menus exactly.
    static let menuRow = Font(NSFont.menuFont(ofSize: 0))
    /// Everything the user reads as content. 13 pt, the macOS default.
    static let primary = Font.body
    /// Captions and help text only, never a row label. 11 pt.
    static let secondary = Font.subheadline
    /// Group headings. Content size, semibold: hierarchy from weight and
    /// colour rather than from shrinking, which is what the guidelines ask for.
    static let sectionHeader = Font.body.weight(.semibold)
}

/// The panel's vertical rhythm.
///
/// With headings at the content's own size, spacing is what separates one group
/// from the next. The rule that matters: `heading` is deliberately tighter than
/// `group`, so a heading binds to the rows beneath it rather than floating
/// between them. HIG lists negative space first among the ways to "group
/// related items", ahead of separator lines.
enum Spacing {
    /// Between top-level groups.
    static let group: CGFloat = 18
    /// Between rows inside a group.
    static let row: CGFloat = 7
    /// Between a heading and the rows it introduces.
    static let heading: CGFloat = 5
    /// Panel edge inset.
    static let edge: CGFloat = 14
}

/// Whether the panel masks the addresses and ALGO amounts.
///
/// An environment value rather than a parameter threaded into each card: a
/// default-false parameter makes omission compile silently, so a new card that
/// renders an amount and forgets the argument would show the real balance
/// during a screen share. The environment flows to every descendant unasked.
private struct ValuesHiddenKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var valuesHidden: Bool {
        get { self[ValuesHiddenKey.self] }
        set { self[ValuesHiddenKey.self] = newValue }
    }
}

/// The names the user gave the watched accounts, beside `valuesHidden` for the
/// same reach: every view that names an account reads them unasked.
private struct AccountNamesKey: EnvironmentKey {
    static let defaultValue = AccountNames()
}

extension EnvironmentValues {
    var accountNames: AccountNames {
        get { self[AccountNamesKey.self] }
        set { self[AccountNamesKey.self] = newValue }
    }
}

/// Severity of a row, taken from the alert that names it.
///
/// Colour in a row is a pointer, not the message: it marks *which* fact the
/// Attention section is talking about. The condition itself is always spelled
/// out there in words, with its own glyph, which is what satisfies the HIG's
/// "avoid relying solely on color to … communicate essential information".
/// Repeating that glyph on the row as well says the same thing twice in the
/// space of two lines.
enum MeterLevel {
    case normal, caution, critical

    /// The one severity-to-level translation for the panel's rows and Attention
    /// entries, so a retuned tint or symbol changes all of them at once instead
    /// of leaving a hardcoded copy behind. The menu bar icon, the Settings
    /// preview and the glyph on each account's row in the panel's list grade
    /// severities separately, through `HealthLevel`.
    init(_ severity: AlertSeverity?) {
        switch severity {
        case .critical: self = .critical
        case .warning: self = .caution
        default: self = .normal
        }
    }

    /// Fill colour for a gauge, which always has one.
    var tint: Color {
        switch self {
        case .normal: .green
        case .caution: .orange
        case .critical: .red
        }
    }

    /// Glyph for an Attention entry: shape carries the severity alongside
    /// colour, for anyone who cannot distinguish the colours.
    var alertSymbol: String {
        self == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill"
    }

    /// Colour for a row's value, or `nil` for the standard secondary style. A
    /// value with no alert against it should not claim to be good, only to be a
    /// value, so `normal` is deliberately not green here.
    var textTint: Color? {
        switch self {
        case .normal: nil
        case .caution: .orange
        case .critical: .red
        }
    }

    /// Spoken by VoiceOver alongside the value, since colour is not available
    /// to it.
    var spoken: String? {
        switch self {
        case .normal: nil
        case .caution: "caution"
        case .critical: "critical"
        }
    }

    /// The style a row's value renders in, shared by every row kind so the
    /// same level can never produce two different colours in one card.
    var valueStyle: AnyShapeStyle {
        textTint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary)
    }

    /// What VoiceOver reads for a value at this level.
    func spokenValue(for detail: String) -> String {
        [detail, spoken].compactMap { $0 }.joined(separator: ", ")
    }
}

/// Metrics that can appear in the menu bar. Any combination, including none.
///
/// `allCases` order is the display order, so the item reads the same however
/// the checkboxes were clicked.
enum MenuBarMetric: String, CaseIterable, Identifiable {
    case round
    case absenceHeadroom
    case keyExpiry
    case proposals24h
    case earned24h

    var id: String { rawValue }

    var title: String {
        switch self {
        case .round: "Round"
        case .absenceHeadroom: "Absence headroom"
        case .keyExpiry: "Key expiry"
        case .proposals24h: "Blocks today"
        case .earned24h: "Earned today"
        }
    }
}

enum MenuBar {
    /// Where the menu bar text has ALGO, which `MenuBarImage` draws as the
    /// Algorand mark. The text keeps a letter there, U+023A, the one the mark
    /// is often typed as, because the text is also stored as the remembered
    /// shapes, and `spokenName` reads it out as ALGO. The panel shows the mark
    /// too, through `Text(algos:style:)`.
    static let algo = "\u{023A}"

    /// Separator between metrics. Narrow, and the standard macOS way to run
    /// several facts together on one line.
    static let separator = " · "

    /// The item's name for VoiceOver: the app and its health, then the metrics,
    /// with the unit as a word and the metrics as a list, where the text has a
    /// letter and a dot that would be read aloud as such.
    static func spokenName(health: HealthLevel, text: String?) -> String {
        let metrics = text.map {
            $0.replacingOccurrences(of: algo, with: "ALGO")
                .replacingOccurrences(of: separator, with: ", ")
        }
        return ["algobuddy: \(health.label)", metrics].compactMap { $0 }.joined(separator: ", ")
    }

    /// How wide the item is: its image, and the room the status item leaves
    /// around an image, measured at about 8 points either side.
    ///
    /// Shown in Settings because the selection is uncapped: a wide item is not
    /// clipped, it is **hidden entirely** behind the notch, with nothing to
    /// indicate why. Better to see the number than to lose the icon.
    static func width(of image: NSImage) -> CGFloat { image.size.width + 16 }

    /// Past this, a crowded menu bar starts dropping items.
    static let comfortableWidth: CGFloat = 136
}

enum Format {
    /// Stand-in for a value the reader has chosen not to display. Bullets keep
    /// a row looking like a row, where a word such as "hidden" would read as a
    /// status and invite the question of what went wrong.
    static func hidden(_ length: Int = 6) -> String { String(repeating: "•", count: length) }

    /// The panel's ALGO amount, or its mask: the one place the two compose, so
    /// every money surface masks identically. The menu bar builds its own
    /// narrower form because its width budget is different, deliberately.
    static func algosLabel(_ amount: MicroAlgos, hidden: Bool) -> String {
        hidden ? "\(Self.hidden()) ALGO" : "\(algos(amount, decimals: 2)) ALGO"
    }

    /// An amount where a row has little room for it: in millions from ten
    /// million on, so no row's amount is wider than `widestRowAmount`. The
    /// account's own page shows it in full.
    static func rowAlgosLabel(_ amount: MicroAlgos, hidden: Bool) -> String {
        guard !hidden, amount.algos >= 10_000_000 else { return algosLabel(amount, hidden: hidden) }
        return String(format: "%.2fM ALGO", amount.algos / 1_000_000)
    }

    /// The widest amount `rowAlgosLabel` gives, in digits of one width.
    static let widestRowAmount = "0000000.00 ALGO"

    /// A shortened address, or its mask, on the same terms as `algosLabel`.
    /// Every surface that shows an address goes through here, by itself or
    /// through `accountLabel`, so a new one cannot show a real address while
    /// values are hidden.
    static func addressLabel(_ value: String, hidden: Bool) -> String {
        hidden ? Self.hidden() : address(value)
    }

    /// What an account goes by: the name the user gave it, otherwise its short
    /// address or that address's mask. A name is never masked. It is the
    /// user's own label, and what tells the accounts apart while their
    /// addresses are hidden.
    static func accountLabel(
        _ address: AlgorandAddress, names: AccountNames, hidden: Bool
    ) -> String {
        names.label(for: address, otherwise: addressLabel(address.stringValue, hidden: hidden))
    }

    /// Compact, and steady: above a million it changes once in 10,000 rounds.
    /// The full round changes every few seconds, and in the menu bar's
    /// proportional digits each change would shove everything to its left
    /// around.
    static func round(_ value: UInt64) -> String {
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
    static func exactRound(_ value: UInt64) -> String { "\(value)" }

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "-" }
        if seconds <= 0 { return "overdue" }
        let days = seconds / 86_400
        if days >= 1 { return String(format: "%.1fd", days) }
        let hours = seconds / 3_600
        if hours >= 1 { return String(format: "%.1fh", hours) }
        return String(format: "%.0fm", max(1, seconds / 60))
    }

    static func algos(_ amount: MicroAlgos, decimals: Int = 2) -> String {
        String(format: "%.\(decimals)f", amount.algos)
    }

    static func relative(_ seconds: TimeInterval) -> String {
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(Int(seconds))s ago" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m ago" }
        // Days matter: a small staker's expected proposal gap runs to days, so
        // without this branch a healthy account reads "156h ago".
        if seconds < 48 * 3_600 { return "\(Int(seconds / 3_600))h ago" }
        return String(format: "%.1fd ago", seconds / 86_400)
    }

    static func address(_ value: String) -> String {
        guard value.count > 16 else { return value }
        return "\(value.prefix(6))…\(value.suffix(6))"
    }
}

extension AccountState {
    /// The participation status and whether proposing pays, as one phrase,
    /// shared by the account's card and its row in the list, so the two cannot
    /// word the same state two ways. "Earning" follows the alerts: an account
    /// outside the payout window does not earn, however eligible it is.
    var statusText: String {
        switch status {
        case .online: earnsPayouts() ? "Online and earning" : "Online, not earning"
        case .offline: "Offline"
        case .notParticipating: "Not participating"
        }
    }

    var statusTint: Color {
        switch status {
        case .online: earnsPayouts() ? .green : .orange
        case .offline: .red
        case .notParticipating: .secondary
        }
    }
}

/// The hover highlight of a menu item, shared by every clickable row in the
/// panel so they all answer the pointer the same way.
struct RowHighlight: ViewModifier {
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            // Without this the row only responds where there is ink.
            .contentShape(Rectangle())
            // `.quaternary`, a hierarchical style: those have vibrant variants
            // and respond to Increase Contrast and Reduce Transparency, where a
            // fixed alpha over a material does neither, and the panel sits on a
            // material.
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(
                        isHovering && isEnabled ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)
                    )
            )
            .onHover { isHovering = $0 }
    }
}
