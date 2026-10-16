import Foundation

/// The stand-in for a figure not yet known, in the shape of the figure it
/// stands for: each digit replaced by a figure dash.
///
/// A figure dash is exactly as wide as a digit in a font with tabular figures,
/// and about as wide as one otherwise, so a stand-in takes the room its figure
/// will, or nearly, and what is set beside it barely moves when the figure
/// arrives. A shape keeps the digits' places and the unit, never the figure,
/// so remembering one reveals no amount.
public enum FigureShape {
    /// U+2012 FIGURE DASH.
    public static let dash: Character = "\u{2012}"

    /// Longer than any menu bar figure, and short enough that nothing read
    /// back from storage can crowd the menu bar.
    static let maxLength = 16

    /// The shape of `figure`, or nil when it has no digit to stand in for, as
    /// a word such as "overdue" or a masked amount has none.
    public static func of(_ figure: String) -> String? {
        guard figure.contains(where: isDigit) else { return nil }
        return String(figure.map { isDigit($0) ? dash : $0 })
    }

    /// Whether `text` can stand in for a figure: it has a figure dash and no
    /// digit, and is no longer than a figure. A shape read back from storage
    /// is put in the menu bar as it is, so it has to be one.
    public static func isShape(_ text: String) -> Bool {
        text.contains(dash) && !text.contains(where: isDigit) && text.count <= maxLength
    }

    private static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }
}
