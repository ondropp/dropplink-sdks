import Foundation

struct HTTPResponse: Sendable, Equatable {
    let statusCode: Int
    let body: Data
    /// The `Retry-After` header in seconds, when present (the HTTP-date form isn't used by the server).
    var retryAfter: TimeInterval? = nil
}

/// The SDK's only network seam. Tests swap in a fake; the app uses `URLSessionHTTPClient`.
protocol HTTPClient: Sendable {
    /// Throws only for transport failures (offline, timeout, TLS). Any HTTP status is a response.
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

final class URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    init() {
        // Ephemeral: no cookies, cache or credentials shared with the host app.
        let configuration = URLSessionConfiguration.ephemeral
        // URLSession has no separate connect timeout; the request timeout is the idle timeout and
        // covers both connecting and waiting for bytes (spec: 10 s connect, 10 s read).
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        // Continuation over dataTask rather than `session.data(for:)`, which needs iOS 15.
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let http = response as? HTTPURLResponse {
                    let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                        .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
                    continuation.resume(returning: HTTPResponse(statusCode: http.statusCode, body: data ?? Data(),
                                                                retryAfter: retryAfter))
                } else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }
            task.resume()
        }
    }
}
