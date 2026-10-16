import XCTest
@testable import WCleanerCore

final class DiskUsageServiceTests: XCTestCase {
    func testParsesDuOutput() {
        let measured = DiskUsageService.parse(ProcessResult(exitCode: 0, stdout: Data("2048\t/tmp/x\n".utf8), stderr: Data()), measuredAt: Date())
        XCTAssertEqual(measured.bytes, 2048 * 1024)

        let partial = DiskUsageService.parse(
            ProcessResult(exitCode: 1, stdout: Data("10\t/tmp/x\n".utf8), stderr: Data("du: /tmp/x/secret: Permission denied\n".utf8)),
            measuredAt: Date()
        )
        guard case .measured(_, _, let isPartial) = partial else { return XCTFail("Expected measured") }
        XCTAssertTrue(isPartial)

        let failed = DiskUsageService.parse(ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("no such file".utf8)), measuredAt: Date())
        guard case .failed = failed else { return XCTFail("Empty output must fail, never be zero") }
    }

    func testMeasuresRealDirectoryIncludingHiddenFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WCleanerTests-du-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(count: 512 * 1024).write(to: directory.appendingPathComponent(".hidden/blob.bin"))
        try Data(count: 512 * 1024).write(to: directory.appendingPathComponent("visible.bin"))

        let service = DiskUsageService()
        let values = await service.measure([directory.path])
        let bytes = try XCTUnwrap(values[directory.path]?.bytes)
        XCTAssertGreaterThanOrEqual(bytes, 1024 * 1024)
    }

    func testMissingDirectoryFailsInsteadOfZero() async {
        let service = DiskUsageService()
        let values = await service.measure(["/definitely/missing/WCleaner"])
        guard case .failed = values["/definitely/missing/WCleaner"] else {
            return XCTFail("Expected failure")
        }
    }

    func testCacheAvoidsRemeasuringUntilStale() async {
        let runner = CountingDuRunner()
        let clock = MutableClock(Date(timeIntervalSince1970: 0))
        let service = DiskUsageService(runner: runner, cacheLifetime: 3600, now: { clock.now })
        let path = FileManager.default.temporaryDirectory.path

        await service.measure([path])
        await service.measure([path])
        XCTAssertEqual(runner.calls, 1)

        clock.advance(3599)
        await service.measure([path])
        XCTAssertEqual(runner.calls, 1)

        clock.advance(2)
        await service.measure([path])
        XCTAssertEqual(runner.calls, 2)

        await service.measure([path], force: true)
        XCTAssertEqual(runner.calls, 3)
    }

    func testConcurrencyIsBounded() async {
        let runner = CountingDuRunner(delay: .milliseconds(50))
        let service = DiskUsageService(runner: runner, maxConcurrent: 2)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("WCleanerTests-bound-\(UUID().uuidString)")
        let paths = (0..<6).map { base.appendingPathComponent("p\($0)").path }
        for path in paths {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: base) }
        await service.measure(paths)
        XCTAssertEqual(runner.calls, 6)
        XCTAssertLessThanOrEqual(runner.maxConcurrent, 2)
    }
}

/// Fake `du` that records how often and how concurrently it was invoked.
final class CountingDuRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private var _active = 0
    private var _maxConcurrent = 0
    private let delay: Duration

    init(delay: Duration = .zero) {
        self.delay = delay
    }

    var calls: Int { lock.withLock { _calls } }
    var maxConcurrent: Int { lock.withLock { _maxConcurrent } }

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        XCTAssertEqual(request.executableURL.path, "/usr/bin/du")
        XCTAssertTrue(request.arguments.contains("-x"), "du must not cross mount points")
        XCTAssertTrue(request.arguments.contains("-P"), "du must not follow symlinks")
        lock.withLock {
            _calls += 1
            _active += 1
            _maxConcurrent = max(_maxConcurrent, _active)
        }
        if delay > .zero { try await Task.sleep(for: delay) }
        lock.withLock { _active -= 1 }
        return ProcessResult(exitCode: 0, stdout: Data("4\t\(request.arguments.last!)\n".utf8), stderr: Data())
    }
}

final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        current = start
    }

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}
