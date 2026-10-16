import XCTest
@testable import WCleanerCore

final class ProcessRunnerTests: XCTestCase {
    private let runner = SubprocessRunner()

    func testCapturesStdoutAndExitCode() async throws {
        let result = try await runner.run(ProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello world"]
        ))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdoutString, "hello world\n")
    }

    func testArgumentsAreNotInterpretedByAShell() async throws {
        let tricky = "$(touch /tmp/should-not-exist); `whoami` && echo pwned"
        let result = try await runner.run(ProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: [tricky]
        ))
        XCTAssertEqual(result.stdoutString, tricky + "\n")
    }

    func testNonZeroExitIsReported() async throws {
        let result = try await runner.run(ProcessRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/false"),
            arguments: []
        ))
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertFalse(result.succeeded)
    }

    func testTimeoutTerminatesProcess() async {
        let start = ContinuousClock.now
        do {
            _ = try await runner.run(ProcessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"],
                timeout: .milliseconds(300)
            ))
            XCTFail("Expected timeout")
        } catch let error as ProcessRunnerError {
            guard case .timedOut = error else { return XCTFail("Unexpected error \(error)") }
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5))
    }

    func testOutputLimitFailsClosed() async {
        do {
            _ = try await runner.run(ProcessRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/yes"),
                arguments: [],
                timeout: .seconds(10),
                maxOutputBytes: 1024
            ))
            XCTFail("Expected output limit error")
        } catch let error as ProcessRunnerError {
            XCTAssertEqual(error, .outputLimitExceeded(bytes: 1024))
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testCancellationStopsProcess() async {
        let runner = self.runner
        let task = Task {
            try await runner.run(ProcessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"],
                timeout: .seconds(30)
            ))
        }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let result = await task.result
        switch result {
        case .success:
            XCTFail("Expected cancellation")
        case .failure(let error):
            XCTAssertEqual(error as? ProcessRunnerError, .cancelled)
        }
    }

    func testMissingExecutable() async {
        do {
            _ = try await runner.run(ProcessRequest(
                executableURL: URL(fileURLWithPath: "/nonexistent/tool"),
                arguments: []
            ))
            XCTFail("Expected error")
        } catch let error as ProcessRunnerError {
            XCTAssertEqual(error, .executableNotFound("/nonexistent/tool"))
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }
}
