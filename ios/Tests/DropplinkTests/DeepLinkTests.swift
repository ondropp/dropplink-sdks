import XCTest
@testable import Dropplink

/// Spec §7 and §10.5.
final class DeepLinkTests: XCTestCase {
    private let link = DeepLink(path: "/product/123", params: ["variant": "red"], url: nil, isDeferred: true)

    func testPendingLinkIsDeliveredOnceAListenerIsSet() {
        let queue = DispatchQueue(label: "test")
        let dispatcher = DeepLinkDispatcher(deliveryQueue: queue)
        dispatcher.dispatch(link)

        let delivered = Recorder<DeepLink>()
        dispatcher.setListener { delivered.append($0) }
        queue.sync {}
        XCTAssertEqual(delivered.values, [link])

        // Delivered once: replacing the listener doesn't replay it.
        let second = Recorder<DeepLink>()
        dispatcher.setListener { second.append($0) }
        queue.sync {}
        XCTAssertTrue(second.values.isEmpty)
    }

    func testOnlyTheLatestPendingLinkIsKept() {
        let queue = DispatchQueue(label: "test")
        let dispatcher = DeepLinkDispatcher(deliveryQueue: queue)
        let newer = DeepLink(path: "/newer", params: [:], url: URL(string: "https://go.brand.com/n"), isDeferred: false)
        dispatcher.dispatch(link)
        dispatcher.dispatch(newer)

        let delivered = Recorder<DeepLink>()
        dispatcher.setListener { delivered.append($0) }
        queue.sync {}
        XCTAssertEqual(delivered.values, [newer])
    }

    func testRemovingTheListenerHoldsLinksAgain() {
        let queue = DispatchQueue(label: "test")
        let dispatcher = DeepLinkDispatcher(deliveryQueue: queue)
        dispatcher.setListener { _ in XCTFail("removed listener called") }
        dispatcher.setListener(nil)
        dispatcher.dispatch(link)

        let delivered = Recorder<DeepLink>()
        dispatcher.setListener { delivered.append($0) }
        queue.sync {}
        XCTAssertEqual(delivered.values, [link])
    }

    func testListenerRunsOnTheMainThreadByDefault() {
        let dispatcher = DeepLinkDispatcher()
        let called = expectation(description: "listener")
        dispatcher.setListener { _ in
            XCTAssertTrue(Thread.isMainThread)
            called.fulfill()
        }
        let link = link
        DispatchQueue.global().async { dispatcher.dispatch(link) }
        wait(for: [called], timeout: 2)
    }

    func testHandleDeepLinkResolvesAndDelivers() async throws {
        let harness = TestHarness()
        harness.http.script("/v1/init", .status(200, try Fixtures.initOrganic()))
        harness.http.script("/v1/deeplink", .status(200, try Fixtures.deeplinkMatched()))
        await harness.initialize()

        let delivered = Recorder<DeepLink>()
        harness.core.dispatcher.setListener { delivered.append($0) }
        let url = URL(string: "https://go.brand.com/summer?s=ig&ref=story")!
        await harness.core.handleDeepLink(url)?.value
        harness.drainDeliveries()

        XCTAssertEqual(delivered.values, [DeepLink(path: "/product/123", params: ["variant": "red", "ref": "story"],
                                                   url: url, isDeferred: false)])
        let request = try XCTUnwrap(harness.http.requests(to: "/v1/deeplink").first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["installId": harness.core.installId!, "url": "https://go.brand.com/summer?s=ig&ref=story"])
    }

    func testUnmatchedLinksDeliverNothing() async throws {
        let harness = TestHarness()
        harness.http.script("/v1/init", .status(200, try Fixtures.initOrganic()))
        harness.http.script("/v1/deeplink", .status(200, try Fixtures.deeplinkNone()),
                            .status(200, #"{"clickId":"c_1","deepLink":null}"#))
        await harness.initialize()
        let delivered = Recorder<DeepLink>()
        harness.core.dispatcher.setListener { delivered.append($0) }

        await harness.core.handleDeepLink(URL(string: "https://other.com/x")!)?.value
        await harness.core.handleDeepLink(URL(string: "https://go.brand.com/no-path")!)?.value
        harness.drainDeliveries()
        XCTAssertEqual(harness.http.requests(to: "/v1/deeplink").count, 2)
        XCTAssertTrue(delivered.values.isEmpty)
    }

    func testNonHTTPURLsAreIgnored() async throws {
        let harness = TestHarness()
        harness.http.script("/v1/init", .status(200, try Fixtures.initOrganic()))
        await harness.initialize()
        XCTAssertNil(harness.core.handleDeepLink(URL(string: "myapp://product/1")!))
        XCTAssertNil(harness.core.handleDeepLink(URL(fileURLWithPath: "/tmp/x")))
        XCTAssertTrue(harness.http.requests(to: "/v1/deeplink").isEmpty)
    }

    func testLinksBeforeInitAreQueuedAndSentAfterInit() async throws {
        let harness = TestHarness()
        harness.http.script("/v1/init", .status(200, try Fixtures.initOrganic()))
        harness.http.script("/v1/deeplink", .status(200, try Fixtures.deeplinkMatched()))

        XCTAssertNil(harness.core.handleDeepLink(URL(string: "https://go.brand.com/a")!), "queued before initialize")
        await harness.initialize()

        let paths = harness.http.requests.compactMap { $0.url?.path }
        XCTAssertEqual(paths, ["/v1/init", "/v1/deeplink"], "deep link sent after init")
    }

    func testUserActivityConvenience() {
        let web = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        web.webpageURL = URL(string: "https://go.brand.com/x")
        XCTAssertTrue(Dropplink.handleUserActivity(web))
        XCTAssertFalse(Dropplink.handleUserActivity(NSUserActivity(activityType: "com.example.other")))
    }
}
