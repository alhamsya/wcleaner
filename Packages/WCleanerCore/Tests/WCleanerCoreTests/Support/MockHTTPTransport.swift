import Foundation
@testable import WCleanerCore

/// Routes requests to handlers; records every request. No network access in tests.
final class MockHTTPTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, [String: String], Data)

    private let lock = NSLock()
    private var routes: [(matcher: @Sendable (URLRequest) -> Bool, handler: Handler)] = []
    private var _requests: [URLRequest] = []

    var requests: [URLRequest] { lock.withLock { _requests } }

    func on(_ matcher: @escaping @Sendable (URLRequest) -> Bool, _ handler: @escaping Handler) {
        lock.withLock { routes.append((matcher, handler)) }
    }

    /// Matches a path (and optionally a token) exactly.
    func on(path: String, token: String? = nil, _ handler: @escaping Handler) {
        on({ request in
            guard request.url?.path == path else { return false }
            if let token { return request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)" }
            return true
        }, handler)
    }

    func json(path: String, token: String? = nil, status: Int = 200, headers: [String: String] = [:], _ body: String) {
        on(path: path, token: token) { _ in (status, headers, Data(body.utf8)) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let handler: Handler? = lock.withLock {
            _requests.append(request)
            return routes.last(where: { $0.matcher(request) })?.handler
        }
        guard let handler else {
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: [:])!
            return (Data("{\"message\":\"Not Found\"}".utf8), response)
        }
        let (status, headers, data) = try handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        return (data, response)
    }
}

/// Records requested sleeps and returns immediately.
final class RecordingSleeper: Sleeper, @unchecked Sendable {
    private let lock = NSLock()
    private var _durations: [Duration] = []
    var durations: [Duration] { lock.withLock { _durations } }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        lock.withLock { _durations.append(duration) }
        await Task.yield()
    }
}

enum GitHubFixtures {
    static func user(id: Int64, login: String) -> String {
        #"{"id": \#(id), "login": "\#(login)", "name": "\#(login.capitalized)"}"#
    }

    static func repository(id: Int64, owner: String, name: String, fork: Bool = false, parent: String? = nil) -> String {
        let parentJSON = parent.map { #", "parent": {"id": 1, "full_name": "\#($0)"}"# } ?? ""
        return #"{"id": \#(id), "name": "\#(name)", "full_name": "\#(owner)/\#(name)", "owner": {"login": "\#(owner)", "id": 5}, "private": true, "fork": \#(fork), "html_url": "https://github.com/\#(owner)/\#(name)", "permissions": {"pull": true, "push": false, "admin": false}\#(parentJSON)}"#
    }

    static func pullRequest(
        number: Int,
        state: String,
        mergedAt: String?,
        headSHA: String,
        headRef: String,
        headRepo: (Int64, String)?,
        baseRepo: (Int64, String)
    ) -> String {
        let merged = mergedAt.map { "\"\($0)\"" } ?? "null"
        let head = headRepo.map { #"{"id": \#($0.0), "full_name": "\#($0.1)"}"# } ?? "null"
        return #"{"number": \#(number), "title": "PR \#(number)", "html_url": "https://github.com/\#(baseRepo.1)/pull/\#(number)", "state": "\#(state)", "merged_at": \#(merged), "head": {"ref": "\#(headRef)", "sha": "\#(headSHA)", "repo": \#(head)}, "base": {"ref": "main", "sha": "0000000000000000000000000000000000000000", "repo": {"id": \#(baseRepo.0), "full_name": "\#(baseRepo.1)"}}}"#
    }
}
