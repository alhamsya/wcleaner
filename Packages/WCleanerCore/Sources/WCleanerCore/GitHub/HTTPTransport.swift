import Foundation

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public enum HTTPTransportError: Error, Sendable, Equatable {
    case notHTTP
}

/// URLSession transport with no disk cache, no cookies, and redirects restricted to the same HTTPS host
/// (so an Authorization header is never forwarded to another host).
public final class URLSessionTransport: NSObject, HTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private let session: URLSession

    public override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        session = URLSession(configuration: configuration)
        super.init()
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request, delegate: self)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPTransportError.notHTTP
        }
        return (data, http)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let original = task.originalRequest,
              let originalURL = original.url,
              let newURL = request.url,
              newURL.scheme == "https",
              newURL.host?.lowercased() == originalURL.host?.lowercased() else {
            // Cross-host or downgraded redirect: stop and let the caller see the 3xx.
            return nil
        }
        var redirected = request
        for (field, value) in original.allHTTPHeaderFields ?? [:] {
            redirected.setValue(value, forHTTPHeaderField: field)
        }
        return redirected
    }
}
