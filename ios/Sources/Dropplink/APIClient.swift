import Foundation

/// Signs and sends one request, retrying per spec §5. Never throws: failures become `APIResult`.
struct APIClient: Sendable {
    enum Result: Equatable {
        case success(Data)
        /// Gave up on this request. `disable` means the key is unusable and nothing else should be sent.
        case failed(disable: Bool)
    }

    /// One attempt, unretried, for callers with their own rules (the event queue, spec §11).
    struct Attempt {
        /// `nil` for a transport error (offline, timeout, TLS).
        let statusCode: Int?
        let body: Data
        let retryAfter: TimeInterval?
        let serverError: ServerError?
        let transportError: Error?

        var isSuccess: Bool { statusCode.map { (200..<300).contains($0) } ?? false }
    }

    let config: DropplinkConfig
    let http: HTTPClient
    let retryPolicy: RetryPolicy
    let log: Log
    let now: @Sendable () -> Date
    let sleep: @Sendable (TimeInterval) async -> Void
    let random: @Sendable () -> Double

    /// A fresh encoder per body (JSONEncoder isn't Sendable). No pretty-printing: bytes are signed as-is.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    /// `path` is relative to the base URL, e.g. `v1/init`. `body` is the exact bytes that get signed and sent.
    func post(_ path: String, body: Data) async -> Result {
        var retry = 0
        while true {
            let result = await attempt(path, body: body)
            if result.isSuccess {
                return .success(result.body)
            }
            let decision = RetryPolicy.decide(statusCode: result.statusCode, errorCode: result.serverError?.code)
            logFailure(path, result)

            switch decision {
            case .disable:
                return .failed(disable: true)
            case .stop:
                return .failed(disable: false)
            case .retry:
                guard let delay = retryPolicy.delay(beforeRetry: retry, random: random()) else {
                    log.error("\(path) failed after \(retry + 1) attempts; will try again next launch")
                    return .failed(disable: false)
                }
                retry += 1
                await sleep(delay)
            }
        }
    }

    /// Sends once and logs a failure the same way `post` does.
    func send(_ path: String, body: Data) async -> Attempt {
        let result = await attempt(path, body: body)
        if !result.isSuccess { logFailure(path, result) }
        return result
    }

    private func attempt(_ path: String, body: Data) async -> Attempt {
        // Timestamp per attempt (not per request): a retry after backoff must still be fresh.
        let timestamp = String(Int64(now().timeIntervalSince1970))
        var request = URLRequest(url: config.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.keyId, forHTTPHeaderField: "X-Key-Id")
        request.setValue(timestamp, forHTTPHeaderField: "X-Timestamp")
        request.setValue(Signer.signature(secret: config.secret, timestamp: timestamp, body: body),
                         forHTTPHeaderField: "X-Signature")
        do {
            let response = try await http.send(request)
            let failed = !(200..<300).contains(response.statusCode)
            return Attempt(statusCode: response.statusCode, body: response.body, retryAfter: response.retryAfter,
                           serverError: failed ? ServerError(data: response.body) : nil, transportError: nil)
        } catch {
            return Attempt(statusCode: nil, body: Data(), retryAfter: nil, serverError: nil, transportError: error)
        }
    }

    private func logFailure(_ path: String, _ attempt: Attempt) {
        guard let statusCode = attempt.statusCode else {
            log.error("\(path) network error: \(attempt.transportError?.localizedDescription ?? "unknown")")
            return
        }
        let serverError = attempt.serverError
        let code = serverError?.code ?? "unknown"
        switch (statusCode, code) {
        case (401, "stale_timestamp"):
            log.error("\(path) 401 stale_timestamp. Device clock looks wrong; retrying")
        case (401, "invalid_key"):
            log.error("""
                \(path) 401 invalid_key. ⚠️ The key \(config.keyId) is unknown or revoked, or its app was \
                deleted. Check the keyId and secret in the Dropplink dashboard. Dropplink is off until next launch.
                """)
        case (400, "platform_mismatch"):
            log.error("\(path) 400 platform_mismatch. This is an android key, used in an ios app. Use the iOS key from the dashboard.")
        default:
            var message = "\(path) \(statusCode) \(code)"
            if let serverError, !serverError.message.isEmpty { message += ": \(serverError.message)" }
            if let details = serverError?.details { message += " details=\(details)" }
            log.error(message)
        }
    }
}
