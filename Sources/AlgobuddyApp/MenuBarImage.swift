import AppKit

/// The menu bar item as one template image: the health symbol, then the
/// metrics, with the Algorand mark wherever the text has `MenuBar.algo`.
///
/// A menu bar extra hands its label to the status item as one image and one
/// plain title. An image inside a `Text` arrives there as an empty attachment,
/// and a second image is dropped, so drawing the whole item is the one way to
/// set the mark in the text. As a template image it still takes the menu bar's
/// own colour, in a light or a dark menu bar and while the item is highlighted.
enum MenuBarImage {
    /// The font the status item draws a title in.
    static var font: NSFont { .menuBarFont(ofSize: 0) }

    // Where the status item itself places an image and a title, measured
    // against its own drawing of them, so the item looks the same as it
    // would with its title drawn by the menu bar.

    /// Between the symbol's alignment rectangle and the text.
    private static let gap: CGFloat = 2.5
    /// The room a status item leaves before an image and after a title,
    /// beyond the room it leaves around an image alone.
    private static let leading: CGFloat = 2
    private static let trailing: CGFloat = 2.5
    /// How far above the centred line the status item sets a title's
    /// baseline.
    private static let baselineLift: CGFloat = 0.5

    /// - Parameter description: What VoiceOver calls the item. The status item
    ///   takes its name from its image's description, so the image carries it.
    static func render(symbol name: String, text: String?, description: String) -> NSImage {
        // Alone, the symbol is what the status item would show anyway.
        guard let text else {
            return NSImage(systemSymbolName: name, accessibilityDescription: description)
                ?? NSImage()
        }
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()

        let font = Self.font
        let lines = text.components(separatedBy: MenuBar.algo).map { run in
            CTLineCreateWithAttributedString(
                NSAttributedString(string: run, attributes: [.font: font]))
        }
        let textWidth =
            lines.reduce(0) { $0 + CTLineGetTypographicBounds($1, nil, nil, nil) }
            + CGFloat(lines.count - 1) * AlgorandMark.advance(for: font)
        // A symbol's alignment rectangle is the part that lines up with text,
        // without the room some symbols keep around their shape.
        let aligned = symbol.alignmentRect
        let textStart = leading + aligned.maxX + gap
        let lineHeight = font.ascender - font.descender
        let size = NSSize(
            width: textStart + textWidth + trailing,
            height: max(symbol.size.height, lineHeight).rounded(.up))

        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            // The symbol's aligned part centred, on a whole point, as the
            // status item places it beside a title.
            let symbolY = ((rect.height - aligned.height) / 2).rounded(.down) - aligned.minY
            symbol.draw(
                in: NSRect(
                    x: leading, y: symbolY, width: symbol.size.width,
                    height: symbol.size.height))
            let baseline = (rect.height - lineHeight) / 2 - font.descender + baselineLift
            var x = textStart
            for (index, line) in lines.enumerated() {
                if index > 0 {
                    AlgorandMark.fill(at: CGPoint(x: x, y: baseline), font: font, in: context)
                    x += AlgorandMark.advance(for: font)
                }
                context.textPosition = CGPoint(x: x, y: baseline)
                CTLineDraw(line, context)
                x += CTLineGetTypographicBounds(line, nil, nil, nil)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }
}

/// The Algorand logo mark, the symbol for ALGO, which no font carries.
///
/// The outline is the one in Algorand's media kit, as Simple Icons publishes
/// it: a single shape on a 24 point square, listed clockwise from the top of
/// its left stroke, with y growing downwards as in the original drawing.
enum AlgorandMark {
    private static let outline: [CGPoint] = [
        CGPoint(x: 13.874, y: 0), CGPoint(x: 17.547, y: 0), CGPoint(x: 19.157, y: 5.963),
        CGPoint(x: 22.946, y: 5.963), CGPoint(x: 20.358, y: 10.463),
        CGPoint(x: 23.982, y: 23.996), CGPoint(x: 20.225, y: 23.996),
        CGPoint(x: 17.785, y: 14.919), CGPoint(x: 12.538, y: 23.998),
        CGPoint(x: 8.345, y: 23.998), CGPoint(x: 16.452, y: 9.947),
        CGPoint(x: 15.148, y: 5.069), CGPoint(x: 4.215, y: 24), CGPoint(x: 0.018, y: 24),
    ]

    /// As tall as a capital letter, so it stands on the baseline like one.
    static func height(for font: NSFont) -> CGFloat { font.capHeight }

    /// The mark and a side bearing either side of it, as a letter has.
    static func advance(for font: NSFont) -> CGFloat {
        height(for: font) + 2 * bearing(for: font)
    }

    /// About half a point at the menu bar's size, close to a capital's own.
    private static func bearing(for font: NSFont) -> CGFloat { font.capHeight * 0.06 }

    /// Fills the mark with its left side bearing at `origin`, standing on the
    /// baseline through it.
    static func fill(at origin: CGPoint, font: NSFont, in context: CGContext) {
        let scale = height(for: font) / 24
        let left = origin.x + bearing(for: font)
        let top = origin.y + height(for: font)
        let path = CGMutablePath()
        path.addLines(
            between: outline.map { CGPoint(x: left + $0.x * scale, y: top - $0.y * scale) })
        path.closeSubpath()
        context.addPath(path)
        context.fillPath()
    }
}
