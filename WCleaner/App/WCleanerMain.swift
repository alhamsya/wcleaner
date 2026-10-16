import AppKit

@main
@MainActor
enum WCleanerMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        // Menu-bar-only: no Dock icon, no main menu bar. LSUIElement in Info.plist does the same at launch.
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
