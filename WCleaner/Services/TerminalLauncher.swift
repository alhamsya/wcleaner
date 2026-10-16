import AppKit

/// Runs a generated script visibly in Terminal. The script lives in a private (0700) temporary folder and
/// deletes itself when it starts. WCleaner never runs interactive tools in the background.
@MainActor
enum TerminalLauncher {
    static func run(script: String) async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent("WCleaner-Terminal", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let file = directory.appendingPathComponent("wcleaner-\(UUID().uuidString).command")
        try Data(script.utf8).write(to: file, options: .withoutOverwriting)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)

        let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
            ?? URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: configuration)
    }
}
