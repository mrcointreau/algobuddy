import AppKit
import SwiftUI

extension Text {
    /// An ALGO label as `Format` writes it, with the Algorand mark in place of
    /// the unit's name, as the menu bar shows it.
    ///
    /// The mark is an image, which a `Text` sets on the baseline but does not
    /// scale with its font, so it is drawn for the text style the label is
    /// shown in. VoiceOver still reads the label as written, unit included.
    init(algos label: String, style: NSFont.TextStyle) {
        let unit = " ALGO"
        guard label.hasSuffix(unit) else {
            self.init(label)
            return
        }
        let mark = Image(nsImage: AlgorandMark.image(for: .preferredFont(forTextStyle: style)))
            .renderingMode(.template)
        self = (Text(label.dropLast(unit.count) + " ") + Text(mark)).accessibilityLabel(label)
    }
}

extension AlgorandMark {
    /// The mark as a template image for text in `font`: as wide as its
    /// advance, standing on the image's bottom edge, which a `Text` sets on
    /// its baseline.
    static func image(for font: NSFont) -> NSImage {
        let size = NSSize(width: advance(for: font), height: height(for: font))
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            fill(at: .zero, font: font, in: context)
            return true
        }
        image.isTemplate = true
        return image
    }
}
