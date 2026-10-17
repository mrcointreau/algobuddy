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

/// Whether the panel masks the addresses, the ALGO amounts and the keys' last
/// valid round.
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

extension MenuBarMetric {
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
