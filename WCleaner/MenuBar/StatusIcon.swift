import AppKit

/// The menu bar glyph: a monochrome "WC" monogram knocked out of a rounded badge.
/// Drawn as a template image so macOS tints it correctly for light, dark and highlighted menu bars.
enum StatusIcon {
    enum Variant {
        case normal
        /// Adds a small dot to signal that something needs attention (errors, accounts to reconnect).
        case attention
    }

    /// What one animation frame adds to the badge. `.none` is the still icon.
    struct Effect: Equatable {
        /// The badge is drawn faded while WCleaner checks repositories.
        var dimmed = false
        /// Position (0…1) of a bright band crossing the faded badge.
        var sweep: CGFloat?
        /// Progress (0…1) of the sparkle shown after a worktree was cleaned up.
        var sparkle: CGFloat?

        static let none = Effect()
    }

    static func image(_ variant: Variant = .normal, effect: Effect = .none) -> NSImage {
        let size = NSSize(width: 22, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            draw(in: NSRect(origin: .zero, size: size), variant: variant, effect: effect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = switch (variant, effect.dimmed) {
        case (_, true): "WCleaner, checking repositories"
        case (.attention, false): "WCleaner, needs attention"
        case (.normal, false): "WCleaner"
        }
        return image
    }

    private static func draw(in bounds: NSRect, variant: Variant, effect: Effect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let badge = NSRect(x: 1, y: 1.5, width: 20, height: 13)
        let badgePath = NSBezierPath(roundedRect: badge, xRadius: 3.5, yRadius: 3.5)
        NSColor.black.withAlphaComponent(effect.dimmed ? 0.45 : 1).setFill()
        badgePath.fill()

        if let sweep = effect.sweep {
            // A soft band that travels from just outside the left edge to just outside the right edge.
            let bandWidth: CGFloat = 9
            let centerX = badge.minX - bandWidth / 2 + sweep * (badge.width + bandWidth)
            let clear = NSColor.black.withAlphaComponent(0)
            if let gradient = NSGradient(colors: [clear, .black, clear]) {
                context.saveGState()
                badgePath.addClip()
                gradient.draw(in: NSRect(x: centerX - bandWidth / 2, y: badge.minY, width: bandWidth, height: badge.height), angle: 0)
                context.restoreGState()
            }
        }

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

        let corner = NSPoint(x: bounds.maxX - 2.5, y: bounds.maxY - 2.5)
        if let sparkle = effect.sparkle {
            // Grows, then shrinks away; replaces the attention dot while it plays.
            let scale = sin(min(max(sparkle, 0), 1) * .pi)
            guard scale > 0.01 else { return }
            let outer = 4.5 * scale
            punchHole(context, at: corner, radius: outer + 1)
            NSColor.black.setFill()
            star(center: corner, outer: outer, inner: outer * 0.32).fill()
        } else if variant == .attention {
            // Clear a ring around the dot so it reads as a separate badge on top of the corner.
            punchHole(context, at: corner, radius: 3.5)
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: corner.x - 2.25, y: corner.y - 2.25, width: 4.5, height: 4.5)).fill()
        }
    }

    private static func punchHole(_ context: CGContext, at center: NSPoint, radius: CGFloat) {
        context.saveGState()
        context.setBlendMode(.destinationOut)
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
        context.restoreGState()
    }

    /// A four-pointed star.
    private static func star(center: NSPoint, outer: CGFloat, inner: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        for index in 0..<8 {
            let radius = index.isMultiple(of: 2) ? outer : inner
            let angle = CGFloat(index) * .pi / 4 + .pi / 2
            let point = NSPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            if index == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        path.close()
        return path
    }
}
