import XCTest
@testable import Dropplink

/// Spec §10.4: the retry rules of §5 against a fake HTTP layer.
final class RetryTests: XCTestCase {
    func testDecisionTable() {
        XCTAssertEqual(RetryPolicy.decide(statusCode: nil, errorCode: nil), .retry, "network error / timeout")
        XCTAssertEqual(RetryPolicy.decide(statusCode: 500, errorCode: nil), .retry)
        XCTAssertEqual(RetryPolicy.decide(statusCode: 503, errorCode: "unavailable"), .retry)
        XCTAssertEqual(RetryPolicy.decide(statusCode: 429, errorCode: "rate_limited"), .retry)
        XCTAssertEqual(RetryPolicy.decide(statusCode: 401, errorCode: "stale_timestamp"), .retry)
        XCTAssertEqual(RetryPolicy.decide(statusCode: 401, errorCode: "invalid_key"), .disable)
        XCTAssertEqual(RetryPolicy.decide(statusCode: 400, errorCode: "platform_mismatch"), .disable)
        XCTAssertEqual(RetryPolicy.decide(statusCode: 401, errorCode: "bad_signature"), .stop)
        XCTAssertEqual(RetryPolicy.decide(statusCode: 400, errorCode: "validation_failed"), .stop)
        XCTAssertEqual(RetryPolicy.decide(statusCode: 404, errorCode: nil), .stop)
    }

    func testBackoffIsOneTwoFourSecondsWithTwentyPercentJitter() {
        let policy = RetryPolicy()
        XCTAssertEqual(policy.delay(beforeRetry: 0, random: 0.5), 1)
        XCTAssertEqual(policy.delay(beforeRetry: 1, random: 0.5), 2)
        XCTAssertEqual(policy.delay(beforeRetry: 2, random: 0.5), 4)
        XCTAssertNil(policy.delay(beforeRetry: 3, random: 0.5), "three retries at most")
        XCTAssertEqual(policy.delay(beforeRetry: 2, random: 0)!, 3.2, accuracy: 1e-9)
        XCTAssertEqual(policy.delay(beforeRetry: 2, random: 1)!, 4.8, accuracy: 1e-9)
    }

    func testServerErrorsRetryThreeTimesThenGiveUp() async throws {
        let harness = TestHarness()
        harness.http.script("/v1/init", .status(503, Fixtures.error("unavailable")))
        await harness.initialize()

        XCTAssertEqual(harness.http.requests(to: "/v1/init").count, 4, "1 attempt + 3 retries")
        XCTAssertEqual(harness.sleeps.values, [1, 2, 4])
        XCTAssertNil(harness.core.attribution)
    }

    func testNetworkErrorsAnd429RetryAndCanRecover() async throws {
        let harness = TestHarness()
        harness.http.script("/v1/init", .networkError, .status(429, Fixtures.error("rate_limited")),
                            .status(200, try Fixtures.initOrganic()))
        await harness.initialize()

        XCTAssertEqual(harness.http.requests(to: "/v1/init").count, 3)
        XCTAssertEqual(harness.sleeps.values, [1, 2])
        XCTAssertEqual(harness.core.attribution?.type, "organic")
    }

    func testStaleTimestampRetriesAndWarnsAboutTheClock() async throws {
        let harness = TestHarness()
        harness.http.script("/v1/init", .status(401, Fixtures.error("stale_timestamp")), .status(200, try Fixtures.initOrganic()))
        await harness.initialize()

        XCTAssertEqual(harness.http.requests(to: "/v1/init").count, 2)
        XCTAssertTrue(harness.logs.values.contains { $0.contains("Device clock looks wrong") })
    }

    func testInvalidKeyStopsEverythingThisLaunch() async throws {
        let harness = TestHarness()
        harness.http.script("/v1/init", .status(401, Fixtures.error("invalid_key")))
        harness.core.handleDeepLink(URL(string: "https://go.brand.com/queued")!)
        await harness.initialize()

        XCTAssertEqual(harness.http.requests(to: "/v1/init").count, 1, "no retries")
        XCTAssertTrue(harness.sleeps.values.isEmpty)
        XCTAssertTrue(harness.logs.values.contains { $0.contains("invalid_key") && $0.contains("ak_3f9c1e2a7b6d4c80") })

        XCTAssertNil(harness.core.handleDeepLink(URL(string: "https://go.brand.com/later")!))
        XCTAssertTrue(harness.http.requests(to: "/v1/deeplink").isEmpty, "queued and later links are dropped")
    }

    func testPlatformMismatchStopsAndExplains() async throws {
        let harness = TestHarness()
        harness.http.script("/v1/init", .status(400, Fixtures.error("platform_mismatch")))
        await harness.initialize()

        XCTAssertEqual(harness.http.requests(to: "/v1/init").count, 1)
        XCTAssertTrue(harness.logs.values.contains { $0.contains("This is an android key, used in an ios app") })
    }

    func testOtherClientErrorsStopAndLogCodeMessageAndDetails() async throws {
        let harness = TestHarness()
        harness.http.script("/v1/init", .status(400, #"{"error":{"code":"validation_failed","message":"Invalid body","details":[{"path":"device","message":"Required"}]}}"#))
        await harness.initialize()

        XCTAssertEqual(harness.http.requests(to: "/v1/init").count, 1)
        let line = try XCTUnwrap(harness.logs.values.first { $0.contains("validation_failed") })
        XCTAssertTrue(line.contains("Invalid body"))
        XCTAssertTrue(line.contains("Required"))

        // Unlike invalid_key, a bad request doesn't switch the SDK off: deep links still resolve.
        harness.http.script("/v1/deeplink", .status(200, try Fixtures.deeplinkNone()))
        await harness.core.handleDeepLink(URL(string: "https://go.brand.com/x")!)?.value
        XCTAssertEqual(harness.http.requests(to: "/v1/deeplink").count, 1)
    }

    func testRetriesResendTheSameSignedBytes() async throws {
        let harness = TestHarness()
        harness.http.script("/v1/init", .networkError, .status(200, try Fixtures.initOrganic()))
        await harness.initialize()
        let signatures = harness.http.requests.compactMap { $0.value(forHTTPHeaderField: "X-Signature") }
        XCTAssertEqual(signatures.count, 2)
        XCTAssertEqual(harness.http.requests.map(\.httpBody), Array(repeating: harness.http.requests[0].httpBody, count: 2),
                       "same bytes every attempt")
    }

    func testLoggingIsOffWithoutDebug() async throws {
        let harness = TestHarness()
        harness.http.script("/v1/init", .status(503, Fixtures.error("unavailable")))
        await harness.initialize(DropplinkConfig(keyId: "ak_3f9c1e2a7b6d4c80", secret: "s",
                                                 baseURL: URL(string: "https://attribution.test")!))
        XCTAssertTrue(harness.logs.values.isEmpty)
    }
}
