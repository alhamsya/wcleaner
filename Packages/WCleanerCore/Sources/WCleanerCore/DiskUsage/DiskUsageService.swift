import Foundation

/// Measures worktree sizes with read-only `/usr/bin/du` subprocesses: one filesystem (`-x`), no symlink
/// following (`-P`), bounded concurrency, background QoS, timeouts, and a cache (about one hour by default).
public actor DiskUsageService {
    private struct CacheEntry {
        let value: DiskUsageValue
        let measuredAt: Date
    }

    public static let duURL = URL(fileURLWithPath: "/usr/bin/du")

    private let runner: any ProcessRunning
    private let maxConcurrent: Int
    private let cacheLifetime: TimeInterval
    private let timeout: Duration
    private let now: @Sendable () -> Date

    private var cache: [String: CacheEntry] = [:]
    private var inFlight: [String: Task<DiskUsageValue, Never>] = [:]
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(
        runner: any ProcessRunning = SubprocessRunner(),
        maxConcurrent: Int = 2,
        cacheLifetime: TimeInterval = 3600,
        timeout: Duration = .seconds(300),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.runner = runner
        self.maxConcurrent = max(1, maxConcurrent)
        self.cacheLifetime = cacheLifetime
        self.timeout = timeout
        self.now = now
    }

    /// The best known value without starting any work.
    public func value(for path: String) -> DiskUsageValue {
        if let entry = cache[path] { return entry.value }
        return inFlight[path] != nil ? .measuring : .unknown
    }

    public func isStale(_ path: String) -> Bool {
        guard let entry = cache[path] else { return true }
        return now().timeIntervalSince(entry.measuredAt) >= cacheLifetime
    }

    /// Measures every path whose cached value is missing or stale (or all of them when `force` is true).
    @discardableResult
    public func measure(_ paths: [String], force: Bool = false) async -> [String: DiskUsageValue] {
        var tasks: [String: Task<DiskUsageValue, Never>] = [:]
        for path in Set(paths) where force || isStale(path) {
            if let existing = inFlight[path] {
                tasks[path] = existing
                continue
            }
            let task = Task { await self.measureOne(path) }
            inFlight[path] = task
            tasks[path] = task
        }
        for (path, task) in tasks {
            let value = await task.value
            inFlight[path] = nil
            if case .measured = value {
                cache[path] = CacheEntry(value: value, measuredAt: now())
            } else if cache[path] == nil || force {
                cache[path] = CacheEntry(value: value, measuredAt: now())
            }
        }
        var result: [String: DiskUsageValue] = [:]
        for path in paths {
            result[path] = value(for: path)
        }
        return result
    }

    public func invalidate(_ path: String) {
        cache[path] = nil
    }

    public func removeAll(except keep: Set<String>) {
        cache = cache.filter { keep.contains($0.key) }
    }

    private func measureOne(_ path: String) async -> DiskUsageValue {
        await acquire()
        defer { release() }
        guard !Task.isCancelled else { return .unknown }
        guard FileManager.default.fileExists(atPath: path) else {
            return .failed("The folder does not exist.")
        }
        let request = ProcessRequest(
            executableURL: Self.duURL,
            arguments: ["-s", "-k", "-x", "-P", "--", path],
            environment: ["LC_ALL": "C", "PATH": "/usr/bin:/bin"],
            timeout: timeout,
            maxOutputBytes: 64 * 1024,
            qualityOfService: .background
        )
        do {
            let result = try await runner.run(request)
            return Self.parse(result, measuredAt: now())
        } catch let error as ProcessRunnerError {
            return .failed(error.description)
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// `du -s -k` prints `<kilobytes>\t<path>`. Exit status 1 with output means some entries were unreadable.
    static func parse(_ result: ProcessResult, measuredAt: Date) -> DiskUsageValue {
        let text = result.stdoutString
        guard let firstLine = text.split(separator: "\n").last,
              let field = firstLine.split(separator: "\t", maxSplits: 1).first,
              let kilobytes = Int64(field.trimmingCharacters(in: .whitespaces)) else {
            let message = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(message.isEmpty ? "du returned no size (exit \(result.exitCode))." : String(message.prefix(200)))
        }
        guard result.exitCode == 0 || result.exitCode == 1 else {
            return .failed("du failed (exit \(result.exitCode)).")
        }
        return .measured(bytes: kilobytes * 1024, measuredAt: measuredAt, partial: result.exitCode != 0)
    }

    private func acquire() async {
        if running < maxConcurrent {
            running += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
