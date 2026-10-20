import Foundation

/// Spec §5: which failures are retried and how long to wait between attempts.
struct RetryPolicy: Sendable {
    /// Waits before retry 1, 2 and 3. Three retries means at most four attempts per launch.
    var delays: [TimeInterval] = [1, 2, 4]
    /// ± fraction applied to each delay so many devices don't retry in lockstep.
    var jitter: Double = 0.2

    enum Decision: Equatable {
        /// Transient: network error, timeout, 5xx, 429, 401 stale_timestamp.
        case retry
        /// This request will never succeed (bad request); other requests still might.
        case stop
        /// The key itself is unusable (invalid_key, platform_mismatch): stop all requests this launch.
        case disable
    }

    /// `statusCode` is `nil` for a transport error.
    static func decide(statusCode: Int?, errorCode: String?) -> Decision {
        guard let statusCode else { return .retry }
        switch statusCode {
        case 429, 500...599:
            return .retry
        case 401 where errorCode == "stale_timestamp":
            return .retry
        case 401 where errorCode == "invalid_key", 400 where errorCode == "platform_mismatch":
            return .disable
        default:
            return .stop
        }
    }

    /// Delay before retry number `retry` (0-based), or `nil` when retries are used up.
    /// `random` is uniform in 0...1 and is injected so tests are deterministic.
    func delay(beforeRetry retry: Int, random: Double) -> TimeInterval? {
        guard retry >= 0, retry < delays.count else { return nil }
        let factor = 1 + jitter * (random * 2 - 1)
        return delays[retry] * factor
    }
}
