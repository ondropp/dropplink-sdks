import XCTest
@testable import Dropplink

/// Spec §3 and §5 (config validation), plus thread-safety basics.
final class LifecycleTests: XCTestCase {
    func testInstallIdIsNilBeforeInitializeAndSetAfter() async throws {
        let harness = TestHarness()
        harness.http.script("/v1/init", .status(200, try Fixtures.initOrganic()))
        XCTAssertNil(harness.core.installId)
        let task = harness.core.initialize(config: TestHarness.config)
        XCTAssertNotNil(harness.core.installId, "available as soon as initialize returns")
        await task?.value
        XCTAssertEqual(harness.core.installId, harness.storage.loadOrCreateInstallId())
    }

    func testSecondInitializeIsIgnored() async throws {
        let harness = TestHarness()
        harness.http.script("/v1/init", .status(200, try Fixtures.initOrganic()))
        await harness.initialize()
        XCTAssertNil(harness.core.initialize(config: TestHarness.config))
        XCTAssertEqual(harness.http.requests(to: "/v1/init").count, 1, "one init per launch")
    }

    func testInvalidConfigDisablesTheSDKAndAlwaysLogs() {
        for config in [
            DropplinkConfig(keyId: "", secret: "s"),
            DropplinkConfig(keyId: "key_123", secret: "s"),
            DropplinkConfig(keyId: "ak_123", secret: ""),
        ] {
            let harness = TestHarness()
            XCTAssertNil(harness.core.initialize(config: config))
            XCTAssertNil(harness.core.installId)
            XCTAssertNil(harness.core.handleDeepLink(URL(string: "https://go.brand.com/x")!))
            XCTAssertTrue(harness.http.requests.isEmpty)
            XCTAssertEqual(harness.logs.values.count, 1, "logged even though debug is off")
            XCTAssertTrue(harness.logs.values[0].contains("SDK disabled"))
        }
    }

    func testConfigDescriptionRedactsTheSecret() {
        let config = DropplinkConfig(keyId: "ak_1", secret: "super-secret")
        XCTAssertFalse(String(describing: config).contains("super-secret"))
    }

    func testConcurrentCallsAreSafe() async throws {
        let harness = TestHarness()
        harness.http.script("/v1/init", .status(200, try Fixtures.initAttributed()))
        harness.http.script("/v1/deeplink", .status(200, try Fixtures.deeplinkMatched()))
        let core = harness.core
        let delivered = Recorder<DeepLink>()

        let initTasks = Recorder<Task<Void, Never>>()
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            switch i % 5 {
            case 0: if let task = core.initialize(config: TestHarness.config) { initTasks.append(task) }
            case 1: core.handleDeepLink(URL(string: "https://go.brand.com/\(i)")!)
            case 2: core.dispatcher.setListener { delivered.append($0) }
            case 3: _ = core.installId
            default: _ = core.attribution
            }
        }
        XCTAssertEqual(initTasks.values.count, 1, "exactly one initialize wins")
        await initTasks.values.first?.value

        XCTAssertEqual(harness.http.requests(to: "/v1/init").count, 1)
        XCTAssertNotNil(core.installId)
        XCTAssertEqual(core.attribution?.type, "attributed")
    }
}
