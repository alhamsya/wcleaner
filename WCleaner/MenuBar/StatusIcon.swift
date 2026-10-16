import AppKit

/// The menu bar glyph: a monochrome "WC" monogram knocked out of a rounded badge.
/// Drawn as a template image so macOS tints it correctly for light, dark and highlighted menu bars.
enum StatusIcon {
    enum Variant {
        case normal
        /// Adds a small dot to signal that something needs attention (errors, accounts to reconnect).
        case attention
    }

    static func image(_ variant: Variant = .normal) -> NSImage {
        let size = NSSize(width: 22, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            draw(in: NSRect(origin: .zero, size: size), variant: variant)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = variant == .attention ? "WCleaner, needs attention" : "WCleaner"
        return image
    }

    private static func draw(in bounds: NSRect, variant: Variant) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let badge = NSRect(x: 1, y: 1.5, width: 20, height: 13)
        NSColor.black.setFill()
        NSBezierPath(roundedRect: badge, xRadius: 3.5, yRadius: 3.5).fill()

        // Knock the letters out of the badge.
        context.saveGState()
        context.setBlendMode(.destinationOut)
        let font = NSFont.systemFont(ofSize: 9.5, weight: .heavy)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
            .kern: -0.3,
        ]
        let text = NSAttributedString(string: "WC", attributes: attributes)
        let textSize = text.size()
        let origin = NSPoint(
            x: badge.midX - textSize.width / 2,
            y: badge.midY - textSize.height / 2 + 0.5
        )
        text.draw(at: origin)
        context.restoreGState()

        if variant == .attention {
            // Clear a ring around the dot so it reads as a separate badge on top of the corner.
            let center = NSPoint(x: bounds.maxX - 2.5, y: bounds.maxY - 2.5)
            context.saveGState()
            context.setBlendMode(.destinationOut)
            NSBezierPath(ovalIn: NSRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7)).fill()
            context.restoreGState()
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - 2.25, y: center.y - 2.25, width: 4.5, height: 4.5)).fill()
        }
    }
}
