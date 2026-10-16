import XCTest
@testable import WCleanerCore

/// Returns canned results and records requests; never starts a process.
final class StubProcessRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [ProcessRequest] = []
    private let result: Result<ProcessResult, ProcessRunnerError>

    init(_ result: Result<ProcessResult, ProcessRunnerError>) {
        self.result = result
    }

    var requests: [ProcessRequest] { lock.withLock { _requests } }

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        lock.withLock { _requests.append(request) }
        return try result.get()
    }
}

final class MoleIntegrationTests: XCTestCase {
    func testLocatesFirstExecutableAndReadsVersionOnly() async {
        let runner = StubProcessRunner(.success(ProcessResult(exitCode: 0, stdout: Data("Mole version 1.34.0\nmacOS: 14.8.3\n".utf8), stderr: Data())))
        let installation = await MoleLocator.locate(
            runner: runner,
            candidates: ["/missing/mo", "/opt/homebrew/bin/mo"],
            isExecutable: { $0 == "/opt/homebrew/bin/mo" }
        )
        XCTAssertEqual(installation, MoleInstallation(path: "/opt/homebrew/bin/mo", version: "1.34.0"))
        XCTAssertEqual(runner.requests.map(\.arguments), [["--version"]], "Detection only asks for the version")
        XCTAssertEqual(runner.requests.first?.timeout, .seconds(5))
    }

    func testMissingMoleAndBrokenVersion() async {
        let runner = StubProcessRunner(.failure(.timedOut(seconds: 5)))
        let none = await MoleLocator.locate(runner: runner, candidates: ["/missing/mo"], isExecutable: { _ in false })
        XCTAssertNil(none)
        XCTAssertTrue(runner.requests.isEmpty)

        let broken = await MoleLocator.locate(runner: runner, candidates: ["/usr/local/bin/mo"], isExecutable: { _ in true })
        XCTAssertEqual(broken, MoleInstallation(path: "/usr/local/bin/mo", version: nil))
    }

    func testVersionParsing() {
        XCTAssertEqual(MoleLocator.parseVersion("Mole version 1.34.0"), "1.34.0")
        XCTAssertEqual(MoleLocator.parseVersion("mo 2.1"), "2.1")
        XCTAssertNil(MoleLocator.parseVersion("no version here"))
    }

    func testPreviewIsADryRunAndCleanNeedsAPreviewFirst() {
        XCTAssertEqual(MoleAction.previewClean.arguments, ["clean", "--dry-run"])
        XCTAssertEqual(MoleAction.open.arguments, [])
        var gate = MoleCleanGate()
        XCTAssertFalse(gate.canOfferClean)
        gate.recordPreview(at: Date())
        XCTAssertTrue(gate.canOfferClean)
    }

    func testScriptQuotesPathsAndRunsOnlyTheRequestedCommand() {
        let installation = MoleInstallation(path: "/Users/o'neil/My Tools/mo", version: "1.34.0")
        let script = MoleTerminalScript.make(installation: installation, action: .previewClean)
        XCTAssertTrue(script.hasPrefix("#!/bin/zsh\n"))
        XCTAssertTrue(script.contains("\n'/Users/o'\\''neil/My Tools/mo' 'clean' '--dry-run'\n"), script)
        XCTAssertFalse(script.contains("'clean'\n"), "The preview never runs a plain clean")
        XCTAssertFalse(script.contains("purge") || script.contains("uninstall"))
        XCTAssertEqual(MoleTerminalScript.shellQuote("a b"), "'a b'")
        XCTAssertEqual(MoleTerminalScript.shellQuote("$(rm -rf ~)"), "'$(rm -rf ~)'")
    }
}
