import Foundation

/// A single subprocess invocation. Executable and arguments are always discrete values;
/// nothing is ever passed through a shell, so paths cannot be interpreted as shell syntax.
public struct ProcessRequest: Sendable {
    public var executableURL: URL
    public var arguments: [String]
    public var currentDirectoryURL: URL?
    public var environment: [String: String]?
    public var timeout: Duration
    /// Maximum number of stdout bytes retained. Exceeding it terminates the process and fails the request.
    public var maxOutputBytes: Int
    public var qualityOfService: QualityOfService

    public init(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        environment: [String: String]? = nil,
        timeout: Duration = .seconds(30),
        maxOutputBytes: Int = 8 * 1024 * 1024,
        qualityOfService: QualityOfService = .utility
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.currentDirectoryURL = currentDirectoryURL
        self.environment = environment
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
        self.qualityOfService = qualityOfService
    }
}

public struct ProcessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { exitCode == 0 }
    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

public enum ProcessRunnerError: Error, Sendable, Equatable, CustomStringConvertible {
    case executableNotFound(String)
    case launchFailed(String)
    case timedOut(seconds: Double)
    case cancelled
    case outputLimitExceeded(bytes: Int)

    public var description: String {
        switch self {
        case .executableNotFound(let path): "Executable not found: \(path)"
        case .launchFailed(let message): "Could not launch process: \(message)"
        case .timedOut(let seconds): "Process timed out after \(Int(seconds)) seconds"
        case .cancelled: "Process was cancelled"
        case .outputLimitExceeded(let bytes): "Process output exceeded \(bytes) bytes"
        }
    }
}

public protocol ProcessRunning: Sendable {
    func run(_ request: ProcessRequest) async throws -> ProcessResult
}

/// Runs subprocesses with `Foundation.Process`, strict timeouts, bounded output and cooperative cancellation.
public struct SubprocessRunner: ProcessRunning {
    public init() {}

    public func run(_ request: ProcessRequest) async throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: request.executableURL.path) else {
            throw ProcessRunnerError.executableNotFound(request.executableURL.path)
        }
        try Task.checkCancellation()
        let execution = ProcessExecution(request: request)
        return try await withTaskCancellationHandler {
            try await execution.start()
        } onCancel: {
            execution.cancel()
        }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

/// Owns one `Process` and its pipes. All mutable state is guarded by `lock`.
private final class ProcessExecution: @unchecked Sendable {
    private static let maxStderrBytes = 64 * 1024

    private let request: ProcessRequest
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lock = NSLock()

    private var continuation: CheckedContinuation<ProcessResult, any Error>?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var stdoutClosed = false
    private var stderrClosed = false
    private var exitStatus: Int32?
    private var launched = false
    private var finished = false
    private var cancelRequested = false

    init(request: ProcessRequest) {
        self.request = request
    }

    func start() async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if cancelRequested {
                finished = true
                lock.unlock()
                continuation.resume(throwing: ProcessRunnerError.cancelled)
                return
            }
            self.continuation = continuation
            lock.unlock()
            launch()
        }
    }

    func cancel() {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        cancelRequested = true
        let canTerminate = launched
        lock.unlock()
        if canTerminate {
            terminate(failingWith: .cancelled)
        }
    }

    private func launch() {
        process.executableURL = request.executableURL
        process.arguments = request.arguments
        if let directory = request.currentDirectoryURL {
            process.currentDirectoryURL = directory
        }
        if let environment = request.environment {
            process.environment = environment
        }
        process.qualityOfService = request.qualityOfService
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData, isStdout: true)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData, isStdout: false)
        }
        process.terminationHandler = { [weak self] finishedProcess in
            self?.processTerminated(status: finishedProcess.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            finish(.failure(ProcessRunnerError.launchFailed(error.localizedDescription)))
            return
        }

        lock.lock()
        launched = true
        let cancelNow = cancelRequested
        lock.unlock()

        if cancelNow {
            terminate(failingWith: .cancelled)
            return
        }

        let seconds = request.timeout.timeInterval
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.terminate(failingWith: .timedOut(seconds: seconds))
        }
    }

    private func consume(_ data: Data, isStdout: Bool) {
        lock.lock()
        if data.isEmpty {
            if isStdout {
                stdoutClosed = true
            } else {
                stderrClosed = true
            }
            lock.unlock()
            (isStdout ? stdoutPipe : stderrPipe).fileHandleForReading.readabilityHandler = nil
            completeIfReady()
            return
        }

        var overflow = false
        if isStdout {
            if stdoutBuffer.count + data.count > request.maxOutputBytes {
                overflow = true
            } else {
                stdoutBuffer.append(data)
            }
        } else {
            let remaining = Self.maxStderrBytes - stderrBuffer.count
            if remaining > 0 {
                stderrBuffer.append(data.prefix(remaining))
            }
        }
        lock.unlock()

        if overflow {
            terminate(failingWith: .outputLimitExceeded(bytes: request.maxOutputBytes))
        }
    }

    private func processTerminated(status: Int32) {
        lock.lock()
        exitStatus = status
        lock.unlock()
        completeIfReady()
    }

    private func completeIfReady() {
        lock.lock()
        guard let status = exitStatus, stdoutClosed, stderrClosed, !finished else {
            lock.unlock()
            return
        }
        let result = ProcessResult(exitCode: status, stdout: stdoutBuffer, stderr: stderrBuffer)
        lock.unlock()
        finish(.success(result))
    }

    /// Fails the request first (so a racing normal exit cannot win), then stops the process.
    private func terminate(failingWith error: ProcessRunnerError) {
        guard finish(.failure(error)) else { return }
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        let process = self.process
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            if process.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }

    @discardableResult
    private func finish(_ result: Result<ProcessResult, any Error>) -> Bool {
        lock.lock()
        guard !finished, let continuation else {
            lock.unlock()
            return false
        }
        finished = true
        self.continuation = nil
        lock.unlock()

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        continuation.resume(with: result)
        return true
    }
}
