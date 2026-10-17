import Foundation
import Testing

@testable import AlgobuddyCore

@Suite("Menu bar text")
struct MenuBarTextTests {
    /// The letter the text has for ALGO, written out rather than read from
    /// `MenuBarText.algo`: remembered shapes carry it, so it must not change.
    static let algo = "\u{023A}"

    /// One figure of each kind the menu bar shows: 3.5 days of absence
    /// headroom, 87 days of keys, 3 blocks and 8.2 ALGO today.
    static func portfolio(
        headroom: TimeInterval = 302_400, hasRewards: Bool = true, isPartial: Bool = false
    ) -> PortfolioSummary {
        var portfolio = PortfolioSummary()
        portfolio.closestAbsenceHeadroom = headroom
        portfolio.closestKeyExpiry = 7_516_800
        portfolio.proposals24h = 3
        portfolio.earned24h = MicroAlgos(8_200_000)
        portfolio.hasRewards = hasRewards
        portfolio.isPartial = isPartial
        return portfolio
    }

    static func text(
        _ metrics: Set<MenuBarMetric> = Set(MenuBarMetric.allCases),
        round: UInt64? = 64_030_256,
        portfolio: PortfolioSummary? = MenuBarTextTests.portfolio(),
        hidden: Bool = false,
        shapes: MenuBarShapes = MenuBarShapes()
    ) -> MenuBarText {
        MenuBarText(
            metrics: metrics, round: round, portfolio: portfolio, valuesHidden: hidden,
            shapes: shapes)
    }

    /// What stands in for `figure`.
    static func shape(_ figure: String) throws -> String {
        try #require(FigureShape.of(figure))
    }

    /// Storage keeps the selection and the remembered shapes under these
    /// names, so a renamed case would forget them.
    @Test("the metrics keep their stored names, in display order")
    func storedNames() {
        #expect(
            MenuBarMetric.allCases.map(\.rawValue) == [
                "round", "absenceHeadroom", "keyExpiry", "proposals24h", "earned24h",
            ])
    }

    @Test("the figures read in display order, one separator apart")
    func figuresInOrder() {
        #expect(Self.text().text == "#64.03M · 3.5d · 87.0d · 3 blk · 8.2 \(Self.algo)")
        #expect(Self.text([.earned24h, .round]).text == "#64.03M · 8.2 \(Self.algo)")
    }

    @Test("no metric leaves the symbol alone, named by its health")
    func iconOnly() {
        let text = Self.text([])
        #expect(text.text == nil)
        #expect(text.spokenName(health: "Healthy") == "algobuddy: Healthy")
    }

    /// The item keeps its width from launch to the first figures, so each
    /// metric holds its place with the shape of a typical figure.
    @Test("before the first figures, each metric stands in with a typical shape")
    func typicalStandIns() throws {
        let standIns = try ["#66.04M", "9.8d", "87.1d", "3 blk", "8.2 \(Self.algo)"].map(
            Self.shape)
        let text = Self.text(round: nil, portfolio: nil)
        #expect(text.text == standIns.joined(separator: " · "))
        #expect(text.spokenName(health: "No data") == "algobuddy: No data")
    }

    @Test("a remembered shape stands in for its metric until the figure comes")
    func rememberedStandIn() throws {
        let wide = try Self.shape("12.3 \(Self.algo)")
        let shapes = MenuBarShapes(stored: ["earned24h": wide])
        #expect(Self.text([.earned24h], portfolio: nil, shapes: shapes).text == wide)
        #expect(Self.text([.earned24h], shapes: shapes).text == "8.2 \(Self.algo)")
    }

    /// Before the indexer answers, or with one account's history missing,
    /// the sums would claim totals nobody knows, at worst no blocks today. The
    /// countdowns come from algod alone, so they show regardless.
    @Test("the proposal figures wait until every account's proposals are current")
    func proposalsWaitForEveryAccount() throws {
        let standIns = "\(try Self.shape("3 blk")) · \(try Self.shape("8.2 \(Self.algo)"))"
        for portfolio in [Self.portfolio(hasRewards: false), Self.portfolio(isPartial: true)] {
            let text = Self.text(portfolio: portfolio)
            #expect(text.text == "#64.03M · 3.5d · 87.0d · \(standIns)")
            #expect(
                text.spokenName(health: "Healthy") == "algobuddy: Healthy, #64.03M, 3.5d, 87.0d")
        }
    }

    @Test("hiding values masks the earnings, figure or stand-in, and nothing else")
    func hidingMasksEarnings() {
        let text = Self.text(hidden: true)
        #expect(text.text == "#64.03M · 3.5d · 87.0d · 3 blk · •••• \(Self.algo)")
        #expect(
            text.spokenName(health: "Healthy")
                == "algobuddy: Healthy, #64.03M, 3.5d, 87.0d, 3 blk, •••• ALGO")
        #expect(
            Self.text([.earned24h], portfolio: nil, hidden: true).text == "•••• \(Self.algo)")
    }

    /// The app draws the mask as wide as this, so hiding values moves neither
    /// the item nor the panel that hangs from it.
    @Test("under the mask is the figure it hides, or that figure's stand-in")
    func textUnderMask() throws {
        #expect(Self.text(hidden: true).textUnderMask == "8.2")
        #expect(Self.text(portfolio: nil, hidden: true).textUnderMask == (try Self.shape("8.2")))
        let shapes = MenuBarShapes(stored: ["earned24h": try Self.shape("12.3 \(Self.algo)")])
        #expect(
            Self.text(portfolio: nil, hidden: true, shapes: shapes).textUnderMask
                == (try Self.shape("12.3")))
        #expect(Self.text().textUnderMask == nil)
        #expect(Self.text([.round], hidden: true).textUnderMask == nil)
    }

    /// VoiceOver would read the text's letter for ALGO as a letter and a
    /// stand-in dash by dash.
    @Test("VoiceOver hears the figures, with ALGO as a word")
    func spokenName() {
        #expect(
            Self.text([.round, .earned24h]).spokenName(health: "Healthy")
                == "algobuddy: Healthy, #64.03M, 8.2 ALGO")
        #expect(
            Self.text([.round, .earned24h], portfolio: nil).spokenName(health: "Attention")
                == "algobuddy: Attention, #64.03M")
    }

    @Test("the shape of each selected figure is remembered, never the figure")
    func remembersShapes() throws {
        let expected = try [
            "round": Self.shape("#64.03M"),
            "absenceHeadroom": Self.shape("3.5d"),
            "keyExpiry": Self.shape("87.0d"),
            "proposals24h": Self.shape("3 blk"),
            "earned24h": Self.shape("8.2 \(Self.algo)"),
        ]
        #expect(Self.text().rememberedShapes.stored == expected)
        #expect(Self.text([.round]).rememberedShapes.stored == ["round": try Self.shape("#64.03M")])
        #expect(Self.text(round: nil, portfolio: nil).rememberedShapes.stored == [:])
    }

    /// A figure that gains a digit has a new shape, so the next stand-in has
    /// the digit too. A metric not shown keeps its shape for when it is
    /// selected again.
    @Test("a new shape replaces the last one, and an unselected metric keeps its own")
    func shapesReplaceAndStay() throws {
        let last = MenuBarShapes(stored: [
            "absenceHeadroom": try Self.shape("9.8d"),
            "keyExpiry": try Self.shape("87.1d"),
        ])
        let text = Self.text(
            [.absenceHeadroom], portfolio: Self.portfolio(headroom: 1_080_000), shapes: last)
        #expect(text.text == "12.5d")
        #expect(
            text.rememberedShapes.stored == [
                "absenceHeadroom": try Self.shape("12.5d"),
                "keyExpiry": try Self.shape("87.1d"),
            ])
    }

    /// A mask or a word such as "overdue" has no digit to keep, so the shape
    /// it would replace stays for the next stand-in.
    @Test("a figure without a digit leaves the last shape in place")
    func digitlessFiguresKeepShapes() throws {
        let last = MenuBarShapes(stored: [
            "absenceHeadroom": try Self.shape("12.5d"),
            "earned24h": try Self.shape("12.3 \(Self.algo)"),
        ])
        let text = Self.text(
            [.absenceHeadroom, .earned24h], portfolio: Self.portfolio(headroom: -60),
            hidden: true, shapes: last)
        #expect(text.text == "overdue · •••• \(Self.algo)")
        #expect(text.rememberedShapes == last)
    }

    /// What storage hands back goes into the menu bar as it is.
    @Test("only a shape under a metric's name comes back from storage")
    func storedShapesAreChecked() throws {
        let shape = try Self.shape("8.2 \(Self.algo)")
        let shapes = MenuBarShapes(stored: [
            "earned24h": shape,
            // A figure rather than its shape, and a name no metric has.
            "round": "#64.03M",
            "earnedToday": shape,
        ])
        #expect(shapes.stored == ["earned24h": shape])
    }
}
