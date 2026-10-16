import Foundation
import Testing

@testable import AlgobuddyCore

@Suite("Figure shape")
struct FigureShapeTests {
    /// The menu bar's own formats: a round, a duration, a block count and an
    /// amount in the Algorand symbol.
    @Test("each digit becomes a figure dash, and the rest stays")
    func digitsBecomeDashes() {
        #expect(FigureShape.of("8.2 \u{023A}") == "\u{2012}.\u{2012} \u{023A}")
        #expect(FigureShape.of("#66.04M") == "#\u{2012}\u{2012}.\u{2012}\u{2012}M")
        #expect(FigureShape.of("87.1d") == "\u{2012}\u{2012}.\u{2012}d")
        #expect(FigureShape.of("13 blk") == "\u{2012}\u{2012} blk")
    }

    /// One character for one, so the stand-in is exactly as wide as the figure
    /// in a font with tabular figures.
    @Test("a shape has as many characters as its figure")
    func shapeKeepsLength() throws {
        for figure in ["8.2 \u{023A}", "109.6 \u{023A}", "#66.04M", "12.3h", "45m"] {
            let shape = try #require(FigureShape.of(figure))
            #expect(shape.count == figure.count)
        }
    }

    @Test("a text without digits has no shape")
    func noDigitsNoShape() {
        #expect(FigureShape.of("overdue") == nil)
        #expect(FigureShape.of("\u{2022}\u{2022}\u{2022}\u{2022} \u{023A}") == nil)
        #expect(FigureShape.of("") == nil)
    }

    /// What storage hands back is shown in the menu bar as it is, so only a
    /// real stand-in passes.
    @Test("only a stand-in passes as a shape")
    func onlyStandInsPass() throws {
        #expect(FigureShape.isShape(try #require(FigureShape.of("#66.04M"))))
        #expect(!FigureShape.isShape("8.2 \u{023A}"))
        #expect(!FigureShape.isShape("\u{023A}"))
        #expect(!FigureShape.isShape("\u{2012}1"))
        #expect(!FigureShape.isShape(String(repeating: "\u{2012}", count: 17)))
    }
}
