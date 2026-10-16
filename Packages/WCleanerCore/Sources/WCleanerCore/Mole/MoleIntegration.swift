import Foundation

/// Optional integration with Mole (`mo`, github.com/tw93/Mole), a separate GPL-3.0 tool the user installs
/// themselves. WCleaner never bundles or links it: it only detects the executable and opens it in Terminal,
/// where the user sees and controls everything. Nothing here runs a Mole cleanup by itself.
public struct MoleInstallation: Sendable, Equatable {
    public let path: String
    public let version: String?

    public init(path: String, version: String?) {
        self.path = path
        self.version = version
    }
}

public enum MoleAction: Sendable, Equatable {
    /// The interactive Mole menu.
    case open
    /// `mo clean --dry-run`: shows what would be removed, removes nothing.
    case previewClean
    /// `mo clean`: only after a preview in this session and a separate confirmation.
    case clean

    public var arguments: [String] {
        switch self {
        case .open: []
        case .previewClean: ["clean", "--dry-run"]
        case .clean: ["clean"]
        }
    }

    public var title: String {
        switch self {
        case .open: "Mole"
        case .previewClean: "Mole clean preview (dry run)"
        case .clean: "Mole clean"
        }
    }
}

public enum MoleLocator {
    public static let candidatePaths = ["/opt/homebrew/bin/mo", "/usr/local/bin/mo"]

    /// Finds `mo` in the standard Homebrew locations and reads its version (`mo --version`, 5 s timeout).
    public static func locate(
        runner: any ProcessRunning = SubprocessRunner(),
        candidates: [String] = candidatePaths,
        isExecutable: @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) async -> MoleInstallation? {
        for path in candidates where isExecutable(path) {
            let request = ProcessRequest(
                executableURL: URL(fileURLWithPath: path),
                arguments: ["--version"],
                environment: GitEnvironment.make(),
                timeout: .seconds(5),
                maxOutputBytes: 16 * 1024
            )
            let version = (try? await runner.run(request)).flatMap { result in
                result.exitCode == 0 ? parseVersion(result.stdoutString + "\n" + result.stderrString) : nil
            }
            return MoleInstallation(path: path, version: version)
        }
        return nil
    }

    /// Extracts the first dotted version number, e.g. "Mole version 1.34.0" → "1.34.0".
    public static func parseVersion(_ output: String) -> String? {
        let pattern = /(\d+)\.(\d+)(?:\.(\d+))?/
        guard let match = output.firstMatch(of: pattern) else { return nil }
        return String(match.output.0)
    }
}

/// Requires a dry-run preview in the current app session before the real cleanup can be offered.
public struct MoleCleanGate: Sendable, Equatable {
    public private(set) var previewedAt: Date?

    public init() {}

    public mutating func recordPreview(at date: Date) {
        previewedAt = date
    }

    public var canOfferClean: Bool { previewedAt != nil }
}

/// Builds the `.command` script that Terminal runs. Visible, user-controlled and self-deleting.
public enum MoleTerminalScript {
    public static func make(installation: MoleInstallation, action: MoleAction) -> String {
        let command = ([installation.path] + action.arguments).map(shellQuote).joined(separator: " ")
        let note: String
        switch action {
        case .open:
            note = "Opened by WCleaner. Mole is a separate tool; use its menu to choose what to do."
        case .previewClean:
            note = "Dry run: Mole lists what it would clean and removes nothing."
        case .clean:
            note = "Mole will clean now. Review its prompts carefully; you can press Control-C to stop."
        }
        return """
        #!/bin/zsh
        rm -f -- "$0"
        clear
        print -r -- \(shellQuote("WCleaner → \(action.title)"))
        print -r -- \(shellQuote(note))
        print -r -- \(shellQuote("$ " + command))
        print
        \(command)
        status_code=$?
        print
        print -r -- "Mole exited with status $status_code. You can close this window."
        """
    }

    /// Single-quotes a word for zsh, so paths with spaces or quotes stay one argument.
    public static func shellQuote(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
