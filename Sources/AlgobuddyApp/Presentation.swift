import AlgobuddyCore
import SwiftUI

/// Overall state, derived from the worst alert currently holding.
enum HealthLevel: Int, Comparable {
    case unknown, ok, warning, critical

    static func < (lhs: HealthLevel, rhs: HealthLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Distinct **shapes**, not just distinct colours.
    ///
    /// Confirmed on macOS 26: the menu bar renders this label as a template
    /// image and strips the tint entirely: a warning shows as a *white*
    /// triangle, not an orange one. The symbol therefore has to carry the whole
    /// signal, which is also what makes it readable to anyone who cannot
    /// distinguish the colours. The tint below still applies in the Settings
    /// preview, where it is not templated.
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
/// With a single type size, spacing is what separates one group from the next.
/// The rule that matters: `heading` is deliberately tighter than `group`, so a
/// heading binds to the rows beneath it rather than floating between them. HIG
/// lists negative space first among the ways to "group related items", ahead of
/// separator lines.
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

/// Whether the panel and menu bar mask the address and ALGO amounts.
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

    /// The one severity-to-level translation for the panel's rows and
    /// Attention entries, so a retuned tint or symbol changes all of them at
    /// once instead of leaving a hardcoded copy behind. The menu bar icon and
    /// the Settings preview grade severities separately, through `HealthLevel`.
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
    /// The Algorand symbol, U+023A. Verified to render in the menu font, and
    /// exactly the same width as a plain "A", so the correct symbol is free.
    /// The panel spells out "ALGO" instead, where there is room for it.
    static let algo = "\u{023A}"

    /// Separator between metrics. Narrow, and the standard macOS way to run
    /// several facts together on one line.
    static let separator = " · "

    /// Roughly how wide the item will be, measured with the real menu font plus
    /// the health glyph and its padding.
    ///
    /// Shown in Settings because the selection is uncapped: a wide item is not
    /// clipped, it is **hidden entirely** behind the notch, with nothing to
    /// indicate why. Better to see the number than to lose the icon.
    static func estimatedWidth(_ text: String) -> CGFloat {
        let font = NSFont.menuFont(ofSize: 0)
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        return width + 22  // glyph plus the item's own padding
    }

    /// Past this, a crowded menu bar starts dropping items.
    static let comfortableWidth: CGFloat = 120
}

enum Format {
    /// Stand-in for a value the reader has chosen not to display. Bullets keep a
    /// row looking like a row, where a word such as "hidden" would read as a
    /// status and invite the question of what went wrong.
    static func hidden(_ length: Int = 6) -> String { String(repeating: "•", count: length) }

    /// The panel's ALGO amount, or its mask: the one place the two compose, so
    /// every money surface masks identically. The menu bar builds its own
    /// narrower form because its width budget is different, deliberately.
    static func algosLabel(_ amount: MicroAlgos, hidden: Bool, decimals: Int = 2) -> String {
        hidden ? "\(Self.hidden()) ALGO" : "\(algos(amount, decimals: decimals)) ALGO"
    }

    /// Compact and, crucially, **fixed width**. A menu bar item that grows a
    /// character every few seconds shoves everything to its left around.
    static func round(_ value: UInt64) -> String {
        if value >= 1_000_000 {
            return String(format: "%.2fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000)
        }
        return "\(value)"
    }

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
