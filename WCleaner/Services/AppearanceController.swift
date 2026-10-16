import AppKit
import WCleanerCore

/// Applies the System / Light / Dark preference to every window, live.
@MainActor
enum AppearanceController {
    static func appearance(for mode: AppearanceMode) -> NSAppearance? {
        switch mode {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    static func apply(_ mode: AppearanceMode, to application: NSApplication = .shared) {
        application.appearance = appearance(for: mode)
    }
}
