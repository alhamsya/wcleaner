import AppKit

/// Small helpers for building native AppKit forms in code.
@MainActor
enum UIFactory {
    static func label(_ text: String, font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    static func boldLabel(_ text: String) -> NSTextField {
        label(text, font: .boldSystemFont(ofSize: NSFont.systemFontSize))
    }

    static func sectionHeader(_ text: String) -> NSTextField {
        let field = label(text, font: .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold))
        field.setAccessibilityRole(.staticText)
        return field
    }

    /// Multi-line secondary text that wraps to the available width.
    static func note(_ text: String, color: NSColor = .secondaryLabelColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = color
        field.isSelectable = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    static func wrapping(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.isSelectable = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    static func button(_ title: String, target: AnyObject?, action: Selector?) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        return button
    }

    static func checkbox(_ title: String, target: AnyObject?, action: Selector?) -> NSButton {
        NSButton(checkboxWithTitle: title, target: target, action: action)
    }

    static func radio(_ title: String, target: AnyObject?, action: Selector?) -> NSButton {
        NSButton(radioButtonWithTitle: title, target: target, action: action)
    }

    static func popup(_ titles: [String], target: AnyObject?, action: Selector?) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: titles)
        popup.target = target
        popup.action = action
        return popup
    }

    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    static func hStack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    static func vStack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    /// A two-column form: trailing-aligned labels, leading-aligned controls.
    static func form(_ rows: [(String, NSView)]) -> NSGridView {
        let grid = NSGridView(views: rows.map { [label($0.0 + ":"), $0.1] })
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        return grid
    }

    static func symbol(_ name: String, description: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: description)
    }

    static func statusDot(color: NSColor, description: String) -> NSImageView {
        let image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: description)
        let view = NSImageView(image: image ?? NSImage())
        view.contentTintColor = color
        view.symbolConfiguration = .init(pointSize: 8, weight: .regular)
        view.setAccessibilityLabel(description)
        return view
    }
}

extension String {
    /// `/Users/me/code` → `~/code`
    var abbreviatedPath: String { (self as NSString).abbreviatingWithTildeInPath }
}
