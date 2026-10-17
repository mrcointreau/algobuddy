import Foundation

/// Metrics that can appear in the menu bar. Any combination, including none.
///
/// `allCases` order is the display order, so the item reads the same however
/// the checkboxes were clicked. Storage keeps the selection and the remembered
/// shapes under the raw values.
public enum MenuBarMetric: String, CaseIterable, Identifiable, Sendable {
    case round
    case absenceHeadroom
    case keyExpiry
    case proposals24h
    case earned24h

    public var id: String { rawValue }
}

/// The menu bar item's text: each selected metric's figure from the data on
/// display, in `allCases` order, with `separator` between them.
///
/// Read from the portfolio rather than from one account: the round is shared
/// by the cycle, the two countdowns show whichever account runs out first, and
/// the proposal figures are sums. With one account watched every one of those
/// is that account's own value.
///
/// Every selected metric always takes its place, as its figure or, while it
/// has none, as a stand-in of about the same width. The panel hangs from the
/// item, and an item that changes width under an open panel moves along the
/// menu bar, which has the system place the panel again, at times against the
/// item's other edge. So the item keeps its width from launch, onboarding
/// included, to the first figures, give or take the few points by which the
/// menu bar's digits differ from one another.
public struct MenuBarText: Sendable {
    /// Where the text has ALGO, which the app draws as the Algorand mark. The
    /// text keeps a letter there, U+023A, the one the mark is often typed as,
    /// because the text is also stored as the remembered shapes, and
    /// `spokenName(health:)` reads it out as ALGO.
    public static let algo = "\u{023A}"

    /// Separator between metrics. Narrow, and the standard macOS way to run
    /// several facts together on one line.
    public static let separator = " · "

    /// Masked rather than dropped: removing the segment would shrink the item
    /// and shove every icon to its left along. The app sets the bullets as
    /// wide as the figure they hide; see `textUnderMask`.
    static let maskedEarned = "\(Format.hidden(4)) \(algo)"

    let metrics: Set<MenuBarMetric>
    let round: UInt64?
    let portfolio: PortfolioSummary?
    let valuesHidden: Bool
    let shapes: MenuBarShapes

    /// - Parameters:
    ///   - metrics: The metrics selected for the menu bar.
    ///   - round: The round of the data on display, or nil while there is
    ///     none.
    ///   - portfolio: What the accounts on display amount to, or nil while
    ///     there are none.
    ///   - valuesHidden: Whether the earnings are masked.
    ///   - shapes: The remembered shapes, for the stand-ins.
    public init(
        metrics: Set<MenuBarMetric>, round: UInt64?, portfolio: PortfolioSummary?,
        valuesHidden: Bool, shapes: MenuBarShapes
    ) {
        self.metrics = metrics
        self.round = round
        self.portfolio = portfolio
        self.valuesHidden = valuesHidden
        self.shapes = shapes
    }

    /// Nil when no metric is selected, which is how "icon only" is expressed.
    public var text: String? {
        let segments = selected.map { figure($0) ?? standIn($0) }
        return segments.isEmpty ? nil : segments.joined(separator: Self.separator)
    }

    /// The item's name for VoiceOver: the app and its health, then the
    /// figures, with the unit as a word and the figures as a list, where the
    /// text has a letter and a dot that would be read aloud as such. Without
    /// the stand-ins, which would be read out dash by dash.
    public func spokenName(health: String) -> String {
        let figures = selected.compactMap(figure).map {
            $0.replacingOccurrences(of: Self.algo, with: "ALGO")
        }
        return (["algobuddy: \(health)"] + figures).joined(separator: ", ")
    }

    /// The text under the mask over the earnings, without the unit, which
    /// stays in view: the figure, or while there is none, its stand-in. For
    /// measuring only, since it is the very figure the mask hides: the app
    /// draws the mask as wide, so hiding values moves neither the item nor the
    /// panel that hangs from it. Nil unless values are hidden and the earnings
    /// are selected.
    public var textUnderMask: String? {
        guard valuesHidden, metrics.contains(.earned24h) else { return nil }
        let hidden = unmaskedFigure(.earned24h) ?? shapes.shape(for: .earned24h)
        return hidden.replacingOccurrences(of: " \(Self.algo)", with: "")
    }

    /// `shapes`, with the shape of each figure shown in place of its metric's
    /// last one, for the stand-ins after a relaunch. A mask or a word such as
    /// "overdue" has no digit, so no shape, and leaves the last one in place,
    /// as a metric not selected keeps its own.
    public var rememberedShapes: MenuBarShapes {
        var remembered = shapes
        for metric in selected {
            guard let figure = figure(metric), let shape = FigureShape.of(figure) else {
                continue
            }
            remembered.stored[metric.rawValue] = shape
        }
        return remembered
    }

    /// The selected metrics, in display order.
    private var selected: [MenuBarMetric] { MenuBarMetric.allCases.filter(metrics.contains) }

    /// A metric's figure from the data on display, masked while values are
    /// hidden, or nil while it has none.
    private func figure(_ metric: MenuBarMetric) -> String? {
        guard metric == .earned24h, valuesHidden else { return unmaskedFigure(metric) }
        return unmaskedFigure(metric).map { _ in Self.maskedEarned }
    }

    /// A metric's figure as it reads with values shown, or nil while it has
    /// none.
    private func unmaskedFigure(_ metric: MenuBarMetric) -> String? {
        // The proposal figures stay silent unless every account's proposals
        // are current, so neither a pending fetch nor a failed one can pass for
        // the total, least of all as "no blocks today". The panel still shows
        // the figures, and says why they are partial.
        let totals = portfolio.flatMap { $0.hasRewards && !$0.isPartial ? $0 : nil }
        switch metric {
        case .round:
            // "#" marks it as an index rather than a quantity.
            return round.map { "#" + Format.round($0) }
        case .absenceHeadroom:
            return portfolio?.closestAbsenceHeadroom.map(Format.duration)
        case .keyExpiry:
            return portfolio?.closestKeyExpiry.map(Format.duration)
        case .proposals24h:
            return totals.map { "\($0.proposals24h) blk" }
        case .earned24h:
            return totals.map { "\(Format.algos($0.earned24h, decimals: 1)) \(Self.algo)" }
        }
    }

    /// What a metric shows while it has no figure.
    private func standIn(_ metric: MenuBarMetric) -> String {
        // The mask hides any figure, so it stands in for one as well.
        if metric == .earned24h, valuesHidden { return Self.maskedEarned }
        return shapes.shape(for: metric)
    }
}

/// The shape of the last figure each menu bar metric showed, remembered across
/// launches, so a stand-in has as many digits as the figure it waits for. See
/// `FigureShape`.
public struct MenuBarShapes: Sendable, Equatable {
    /// Each shape under its metric's raw value, as storage keeps it.
    public internal(set) var stored: [String: String] = [:]

    public init() {}

    /// Shapes read back from storage. Only a shape under a metric's raw value
    /// is kept, since it goes into the menu bar as it is.
    public init(stored: [String: String]) {
        self.stored = stored.filter { key, shape in
            MenuBarMetric(rawValue: key) != nil && FigureShape.isShape(shape)
        }
    }

    /// The shape a metric's stand-in takes: the shape of the last figure it
    /// showed, and before any, the shape of a typical one.
    func shape(for metric: MenuBarMetric) -> String {
        stored[metric.rawValue] ?? FigureShape.of(Self.typicalFigure(metric)) ?? ""
    }

    /// A figure of the usual width for each metric, whose shape stands in for
    /// it before the first figure.
    private static func typicalFigure(_ metric: MenuBarMetric) -> String {
        switch metric {
        case .round: "#66.04M"
        case .absenceHeadroom: "9.8d"
        case .keyExpiry: "87.1d"
        case .proposals24h: "3 blk"
        case .earned24h: "8.2 \(MenuBarText.algo)"
        }
    }
}
