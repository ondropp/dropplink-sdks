import XCTest
@testable import Dropplink

/// Spec §10.7: the §11 queue rules. Response table, caps and drop order, identify-before-events
/// ordering, persistence across a restart and `setTrackingEnabled(false)`.
final class EventQueueTests: XCTestCase {
    /// A harness whose init succeeds, with the queue empty.
    private func readyHarness(_ harness: TestHarness = TestHarness()) async throws -> TestHarness {
        harness.http.script("/v1/init", .status(200, try Fixtures.initOrganic()))
        await harness.initialize()
        return harness
    }

    private func eventNames(_ harness: TestHarness) -> [String] {
        harness.events.snapshot.items.compactMap { $0.event?.name }
    }

    private func sentNames(_ body: [String: Any]) -> [String] {
        (body["events"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    // MARK: Response table

    func testOK200RemovesAcceptedDuplicatesAndRejectedAndLogsThem() async throws {
        let harness = try await readyHarness()
        harness.http.script("/v1/events", .status(200, String(decoding: try Contract.data("events/response.partial.json"), as: UTF8.self)))
        harness.events.track("add_to_cart", props: ["sku": "TSHIRT-M"], revenue: nil)
        harness.events.track("purchase", props: nil, revenue: Revenue(amount: 499, currency: "INR"))
        await harness.fireTimers()

        XCTAssertEqual(harness.http.requests(to: "/v1/events").count, 1, "one batch")
        XCTAssertTrue(harness.events.snapshot.isEmpty)
        let logs = harness.logs.values
        XCTAssertTrue(logs.contains("Dropplink: track add_to_cart (queued, 1 waiting)"), "\(logs)")
        XCTAssertTrue(logs.contains("Dropplink: events 200: 1 accepted, 0 duplicates, 1 rejected"))
        XCTAssertTrue(logs.contains { $0.contains("rejected: too_old") })
        XCTAssertTrue(logs.contains { $0.contains("pii_in_props: email") })
        XCTAssertFalse(logs.contains { $0.contains("TSHIRT-M") }, "never log prop values")
        XCTAssertTrue(harness.scheduler.pending.isEmpty, "nothing left to retry")
    }

    func testServerErrorsBackOffHonouringRetryAfterThenRecover() async throws {
        let harness = try await readyHarness()
        harness.http.script("/v1/events",
                            .retryAfter(503, Fixtures.error("storage_unavailable"), 30),
                            .networkError,
                            .status(429, Fixtures.error("rate_limited")),
                            .status(200, Fixtures.eventsOK(accepted: 1)),
                            .status(500, Fixtures.error("internal")))
        harness.events.track("add_to_cart", props: nil, revenue: nil)

        await harness.fireTimers() // debounce → 503
        XCTAssertEqual(harness.scheduler.pending, [30], "Retry-After (30 s) beats the 1 s backoff")
        XCTAssertEqual(eventNames(harness), ["add_to_cart"], "kept")

        await harness.fireTimers() // retry → network error
        XCTAssertEqual(harness.scheduler.pending, [2])
        await harness.fireTimers() // retry → 429
        XCTAssertEqual(harness.scheduler.pending, [4])
        await harness.fireTimers() // retry → 200
        XCTAssertTrue(harness.events.snapshot.isEmpty)
        XCTAssertTrue(harness.scheduler.pending.isEmpty)

        // The backoff starts again from 1 s after a 200.
        harness.events.track("add_to_cart", props: nil, revenue: nil)
        await harness.fireTimers() // → 500
        XCTAssertEqual(harness.scheduler.pending, [1])
        XCTAssertEqual(harness.http.requests(to: "/v1/events").count, 5)
        XCTAssertTrue(harness.sleeps.values.isEmpty, "the queue waits on timers, not on sleeps")
    }

    func testQueueBackoffSchedule() {
        XCTAssertEqual(RetryPolicy.queueDelay(beforeRetry: 0, random: 0.5, retryAfter: nil), 1)
        XCTAssertEqual(RetryPolicy.queueDelay(beforeRetry: 1, random: 0.5, retryAfter: nil), 2)
        XCTAssertEqual(RetryPolicy.queueDelay(beforeRetry: 2, random: 0.5, retryAfter: nil), 4)
        XCTAssertEqual(RetryPolicy.queueDelay(beforeRetry: 8, random: 0.5, retryAfter: nil), 256)
        XCTAssertEqual(RetryPolicy.queueDelay(beforeRetry: 9, random: 0.5, retryAfter: nil), 300, "capped at 5 min")
        XCTAssertEqual(RetryPolicy.queueDelay(beforeRetry: 10_000, random: 0.5, retryAfter: nil), 300, "never runs out")
        XCTAssertEqual(RetryPolicy.queueDelay(beforeRetry: 2, random: 0, retryAfter: nil), 3.2, accuracy: 1e-9)
        XCTAssertEqual(RetryPolicy.queueDelay(beforeRetry: 2, random: 1, retryAfter: nil), 4.8, accuracy: 1e-9)
        XCTAssertEqual(RetryPolicy.queueDelay(beforeRetry: 0, random: 0.5, retryAfter: 0.5), 1, "a shorter Retry-After doesn't win")
        XCTAssertEqual(RetryPolicy.queueDelay(beforeRetry: 9, random: 0.5, retryAfter: 600), 600)
    }

    func testStaleTimestampBacksOffAndWarnsAboutTheClock() async throws {
        let harness = try await readyHarness()
        harness.http.script("/v1/events", .status(401, Fixtures.error("stale_timestamp")))
        harness.events.track("add_to_cart", props: nil, revenue: nil)
        await harness.fireTimers()

        XCTAssertEqual(harness.scheduler.pending, [1])
        XCTAssertEqual(eventNames(harness), ["add_to_cart"])
        XCTAssertTrue(harness.logs.values.contains { $0.contains("Device clock looks wrong") })
    }

    func testOther401KeepsEverythingAndStopsUntilNextLaunch() async throws {
        let harness = try await readyHarness()
        harness.http.script("/v1/events", .status(401, Fixtures.error("bad_signature")))
        harness.events.track("add_to_cart", props: nil, revenue: nil)
        await harness.fireTimers()

        XCTAssertEqual(eventNames(harness), ["add_to_cart"], "kept for the next launch")
        XCTAssertTrue(harness.scheduler.pending.isEmpty, "no retry")
        XCTAssertTrue(harness.logs.values.contains { $0.contains("paused until next launch") })

        harness.events.track("purchase", props: nil, revenue: nil)
        await harness.fireTimers()
        XCTAssertNil(harness.events.flush(.background))
        XCTAssertEqual(harness.http.requests(to: "/v1/events").count, 1, "nothing more sent this launch")

        // Next launch: sent again.
        let next = TestHarness(defaults: harness.defaults, queueFile: harness.queueFile)
        next.http.script("/v1/events", .status(200, Fixtures.eventsOK(accepted: 2)))
        _ = try await readyHarness(next)
        XCTAssertEqual(next.bodies(to: "/v1/events").map(sentNames), [["add_to_cart", "purchase"]])
    }

    func testUnknownInstallRunsInitAgainThenRetries() async throws {
        let harness = try await readyHarness()
        harness.http.script("/v1/events", .status(404, Fixtures.error("unknown_install")), .status(200, Fixtures.eventsOK(accepted: 1)))
        harness.events.track("add_to_cart", props: nil, revenue: nil)
        await harness.fireTimers()

        XCTAssertEqual(harness.paths, ["/v1/init", "/v1/events", "/v1/init", "/v1/events"])
        XCTAssertTrue(harness.events.snapshot.isEmpty)
    }

    func testUnknownInstallBacksOffWhenThatInitFails() async throws {
        let harness = TestHarness()
        harness.http.script("/v1/init", .status(200, try Fixtures.initOrganic()), .status(503, Fixtures.error("unavailable")))
        await harness.initialize()
        harness.http.script("/v1/events", .status(404, Fixtures.error("unknown_install")))
        harness.events.track("add_to_cart", props: nil, revenue: nil)
        await harness.fireTimers()

        XCTAssertEqual(harness.http.requests(to: "/v1/init").count, 5, "first init + re-init with its 3 retries")
        XCTAssertEqual(harness.scheduler.pending, [1], "backs off as for 503")
        XCTAssertEqual(eventNames(harness), ["add_to_cart"])
    }

    func testUnknownInstallDoesNotLoopWhenInitSucceedsButTheServerStillDoesNotKnowIt() async throws {
        let harness = try await readyHarness()
        harness.http.script("/v1/events", .status(404, Fixtures.error("unknown_install")))
        harness.events.track("add_to_cart", props: nil, revenue: nil)
        await harness.fireTimers()

        XCTAssertEqual(harness.http.requests(to: "/v1/events").count, 2, "one re-init per failure, then backoff")
        XCTAssertEqual(harness.scheduler.pending, [1])
    }

    func testBadRequestDropsThatBatchOrIdentifyAndCarriesOn() async throws {
        let harness = try await readyHarness()
        harness.http.script("/v1/identify", .status(400, Fixtures.error("pii_in_user_id")))
        harness.http.script("/v1/events", .status(400, Fixtures.error("validation_failed")), .status(200, Fixtures.eventsOK(accepted: 1)))
        harness.events.track("first", props: nil, revenue: nil)
        harness.events.identify(userId: "user_8812", email: nil, phone: nil)
        harness.events.track("second", props: nil, revenue: nil)
        await harness.fireTimers()

        XCTAssertEqual(harness.paths.dropFirst(), ["/v1/events", "/v1/identify", "/v1/events"])
        XCTAssertEqual(harness.bodies(to: "/v1/events").map(sentNames), [["first"], ["second"]])
        XCTAssertTrue(harness.events.snapshot.isEmpty)
        XCTAssertTrue(harness.logs.values.contains { $0.contains("dropped after 400 validation_failed") })
        XCTAssertTrue(harness.logs.values.contains { $0.contains("identify user_8812 dropped after 400 pii_in_user_id") })
    }

    func testOtherClientErrorsDropTheBatchSoTheQueueDoesntJam() async throws {
        let harness = try await readyHarness()
        harness.http.script("/v1/events", .status(413, Fixtures.error("fst_err_ctp_body_too_large")), .status(200, Fixtures.eventsOK(accepted: 1)))
        harness.events.track("first", props: nil, revenue: nil)
        await harness.fireTimers()
        harness.events.track("second", props: nil, revenue: nil)
        await harness.fireTimers()

        XCTAssertEqual(harness.bodies(to: "/v1/events").map(sentNames), [["first"], ["second"]])
        XCTAssertTrue(harness.events.snapshot.isEmpty)
        XCTAssertTrue(harness.logs.values.contains { $0.contains("dropped after 413") })
    }

    // MARK: When it sends

    func testNothingIsSentBeforeThisLaunchsInitSucceeds() async throws {
        let harness = TestHarness()
        harness.events.track("app_open", props: nil, revenue: nil)
        await harness.fireTimers()
        XCTAssertTrue(harness.http.requests.isEmpty, "before initialize")

        harness.http.script("/v1/init", .status(503, Fixtures.error("unavailable")))
        await harness.initialize()
        await harness.fireTimers()
        XCTAssertNil(harness.events.flush(.background))
        XCTAssertTrue(harness.http.requests(to: "/v1/events").isEmpty, "init failed this launch")
        XCTAssertEqual(eventNames(harness), ["app_open"], "kept for the next launch")
    }

    func testFlushesRightAfterASuccessfulInit() async throws {
        let harness = TestHarness()
        harness.http.script("/v1/events", .status(200, Fixtures.eventsOK(accepted: 1)))
        harness.events.track("app_open", props: nil, revenue: nil)
        harness.drainEvents()
        _ = try await readyHarness(harness)

        XCTAssertEqual(harness.paths, ["/v1/init", "/v1/events"])
        XCTAssertTrue(harness.events.snapshot.isEmpty)
    }

    func testDebounceIsOneSecondAfterTheLastCall() async throws {
        let harness = try await readyHarness()
        harness.events.track("a", props: nil, revenue: nil)
        harness.events.track("b", props: nil, revenue: nil)
        harness.events.identify(userId: "u1", email: nil, phone: nil)
        harness.drainEvents()
        XCTAssertEqual(harness.scheduler.pending, [1], "earlier timers are cancelled")
        XCTAssertTrue(harness.http.requests(to: "/v1/events").isEmpty, "nothing sent before the timer fires")
    }

    func testDebounceWaitsForABackoffButBackgroundDoesNot() async throws {
        let harness = try await readyHarness()
        harness.http.script("/v1/events", .networkError, .status(200, Fixtures.eventsOK(accepted: 2)))
        harness.events.track("a", props: nil, revenue: nil)
        await harness.fireTimers()
        XCTAssertEqual(harness.scheduler.pending, [1])

        XCTAssertNil(harness.events.flush(.debounce), "a debounce doesn't cut a backoff short")
        harness.events.track("b", props: nil, revenue: nil)
        harness.drainEvents()
        await harness.events.flush(.background)?.value
        XCTAssertTrue(harness.events.snapshot.isEmpty, "going to the background sends at once")
        XCTAssertEqual(harness.bodies(to: "/v1/events").last.map(sentNames), ["a", "b"])
    }

    // MARK: Ordering and batching

    func testIdentifyReachesTheServerBeforeLaterEvents() async throws {
        let harness = try await readyHarness()
        harness.http.script("/v1/events", .status(200, Fixtures.eventsOK(accepted: 1)))
        harness.http.script("/v1/identify", .status(200, try Fixtures.identifyOK()))
        harness.events.track("before_login", props: nil, revenue: nil)
        harness.events.identify(userId: "user_8812", email: "priya@example.com", phone: nil)
        harness.events.track("after_login", props: nil, revenue: nil)
        harness.events.logout()
        harness.events.track("after_logout", props: nil, revenue: nil)
        await harness.fireTimers()

        XCTAssertEqual(harness.paths.dropFirst(), ["/v1/events", "/v1/identify", "/v1/events", "/v1/identify", "/v1/events"])
        XCTAssertEqual(harness.bodies(to: "/v1/events").map(sentNames), [["before_login"], ["after_login"], ["after_logout"]])
        let identifies = harness.bodies(to: "/v1/identify")
        XCTAssertEqual(identifies.first?["userId"] as? String, "user_8812")
        XCTAssertNotNil((identifies.first?["traits"] as? [String: Any])?["emailHash"])
        XCTAssertTrue(identifies.last?["userId"] is NSNull, "logout is userId: null")
        XCTAssertNil(identifies.last?["traits"])
        XCTAssertTrue(harness.logs.values.contains("Dropplink: identify user_8812 sent"))
        XCTAssertFalse(harness.logs.values.contains { $0.contains("priya") || $0.contains("emailHash") }, "never log traits")
    }

    func testBatchesHoldAtMost100EventsAnd60KB() async throws {
        let harness = try await readyHarness()
        harness.http.script("/v1/events", .status(200, Fixtures.eventsOK(accepted: 100)))
        for i in 0..<250 { harness.events.track("e\(i)", props: nil, revenue: nil) }
        await harness.fireTimers()
        XCTAssertEqual(harness.bodies(to: "/v1/events").map { sentNames($0).count }, [100, 100, 50])

        var big: [String: Any] = [:]
        for i in 0..<20 { big["p\(i)"] = String(repeating: "x", count: 256) }
        for i in 0..<30 { harness.events.track("big\(i)", props: big, revenue: nil) }
        await harness.fireTimers()
        let sizes = harness.http.requests(to: "/v1/events").dropFirst(3).compactMap { $0.httpBody?.count }
        XCTAssertGreaterThan(sizes.count, 1, "split by size, not count")
        XCTAssertTrue(sizes.allSatisfy { $0 <= 60 * 1024 }, "\(sizes)")
        XCTAssertTrue(harness.events.snapshot.isEmpty)
    }

    // MARK: Caps

    private func makeEvent(_ name: String, revenue: Bool = false, ts: Int64 = 1_760_700_000, props: [String: PropValue]? = nil) -> QueuedEvent {
        QueuedEvent(eventId: UUID().uuidString.lowercased(), name: name, ts: ts, props: props,
                    revenue: revenue ? WireRevenue(amount: 1, currency: "INR", orderId: nil) : nil)
    }

    func testEventCapDropsTheOldestNonRevenueEventFirst() {
        var queue = EventQueue()
        queue.append(QueuedIdentify(userId: "u1", traits: nil))
        XCTAssertEqual(queue.append(makeEvent("paid_first", revenue: true)), .added(evicted: 0))
        for i in 0..<999 { _ = queue.append(makeEvent("e\(i)")) }
        XCTAssertEqual(queue.eventCount, 1_000)

        XCTAssertEqual(queue.append(makeEvent("newest")), .added(evicted: 1))
        XCTAssertEqual(queue.eventCount, 1_000)
        let names = queue.items.compactMap { $0.event?.name }
        XCTAssertEqual(names.first, "paid_first", "revenue events are kept")
        XCTAssertFalse(names.contains("e0"), "oldest non-revenue event dropped")
        XCTAssertEqual(names.last, "newest")
        XCTAssertEqual(queue.items.first, .identify(QueuedIdentify(userId: "u1", traits: nil)), "identify is never dropped")
    }

    func testWhenOnlyRevenueEventsAreLeft() {
        var queue = EventQueue()
        for i in 0..<1_000 { _ = queue.append(makeEvent("paid\(i)", revenue: true)) }
        XCTAssertEqual(queue.append(makeEvent("view")), .rejected, "a new event without revenue is dropped")
        XCTAssertEqual(queue.append(makeEvent("paid_new", revenue: true)), .added(evicted: 1))
        let names = queue.items.compactMap { $0.event?.name }
        XCTAssertEqual(names.count, 1_000)
        XCTAssertEqual(names.first, "paid1", "else the oldest revenue event goes")
        XCTAssertEqual(names.last, "paid_new")
    }

    func testByteCapIsOneMegabyte() {
        var queue = EventQueue()
        var props: [String: PropValue] = [:]
        for i in 0..<20 { props["p\(i)"] = .string(String(repeating: "x", count: 256)) }
        var evicted = 0
        for i in 0..<400 {
            if case .added(let n) = queue.append(makeEvent("big\(i)", props: props)) { evicted += n }
        }
        XCTAssertGreaterThan(evicted, 0)
        XCTAssertLessThan(queue.eventCount, 400)
        XCTAssertLessThanOrEqual(queue.byteCount, EventQueue.maxBytes)
        XCTAssertLessThanOrEqual(try APIClient.makeEncoder().encode(queue.file).count, EventQueue.maxBytes, "the real file too")
        XCTAssertEqual(queue.items.last?.event?.name, "big399", "the newest is kept")
    }

    func testEventsOlderThanSevenDaysAreDroppedBeforeAFlush() async throws {
        let clock = TestClock()
        let harness = try await readyHarness(TestHarness(clock: clock))
        harness.http.script("/v1/events", .status(200, Fixtures.eventsOK(accepted: 1)))
        harness.events.track("old", props: nil, revenue: nil)
        harness.drainEvents()
        clock.advance(7 * 24 * 3600 + 1)
        harness.events.track("fresh", props: nil, revenue: nil)
        await harness.fireTimers()

        XCTAssertEqual(harness.bodies(to: "/v1/events").map(sentNames), [["fresh"]])
        XCTAssertTrue(harness.logs.values.contains { $0.contains("older than 7 days") })
    }

    func testEventsOlderThanSevenDaysAreDroppedOnLoad() throws {
        let first = TestHarness()
        first.events.track("old", props: nil, revenue: nil)
        first.drainEvents()

        let later = TestHarness(defaults: first.defaults, queueFile: first.queueFile, clock: TestClock(1_760_700_000 + 8 * 24 * 3600))
        XCTAssertTrue(later.events.snapshot.isEmpty)
    }

    // MARK: Persistence

    func testQueueSurvivesARestart() async throws {
        let first = TestHarness()
        first.events.track("add_to_cart", props: ["qty": 2], revenue: nil)
        first.events.identify(userId: "user_8812", email: nil, phone: nil)
        first.events.track("purchase", props: nil, revenue: Revenue(amount: 499, currency: "INR", orderId: "A1023"))
        first.drainEvents()
        let saved = first.events.snapshot

        let file = try JSONSerialization.jsonObject(with: Data(contentsOf: first.queueFile)) as? [String: Any]
        XCTAssertEqual(file?["v"] as? Int, 1)
        XCTAssertEqual(file?["lastUserId"] as? String, "user_8812")
        XCTAssertEqual((file?["items"] as? [[String: Any]])?.compactMap { $0["kind"] as? String }, ["event", "identify", "event"])

        let second = TestHarness(defaults: first.defaults, queueFile: first.queueFile)
        XCTAssertEqual(second.events.snapshot, saved, "same items, same eventIds and ts")
        second.http.script("/v1/events", .status(200, Fixtures.eventsOK(accepted: 1)))
        second.http.script("/v1/identify", .status(200, try Fixtures.identifyOK()))
        _ = try await readyHarness(second)

        XCTAssertEqual(second.paths, ["/v1/init", "/v1/events", "/v1/identify", "/v1/events"])
        let sentIds = second.bodies(to: "/v1/events").flatMap { ($0["events"] as? [[String: Any]] ?? []).compactMap { $0["eventId"] as? String } }
        XCTAssertEqual(sentIds, saved.items.compactMap { $0.event?.eventId })
        XCTAssertTrue(second.events.snapshot.isEmpty)
        second.drainEvents()
        let emptied = try JSONDecoder().decode(QueueFile.self, from: Data(contentsOf: first.queueFile))
        XCTAssertTrue(emptied.items.isEmpty)
        XCTAssertEqual(emptied.lastUserId, "user_8812", "remembered after sending")

        second.events.identify(userId: "user_8812", email: nil, phone: nil)
        second.drainEvents()
        XCTAssertTrue(second.events.snapshot.isEmpty, "same user after a restart: still a no-op")
    }

    func testACorruptFileIsDiscarded() throws {
        let harness = TestHarness()
        try FileManager.default.createDirectory(at: harness.queueFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: harness.queueFile)
        let config = TestHarness.config
        harness.http.script("/v1/init", .networkError)
        _ = harness.core.initialize(config: config) // turns on debug logging

        XCTAssertTrue(harness.events.snapshot.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.queueFile.path))
        XCTAssertTrue(harness.logs.values.contains { $0.contains("couldn't be read; discarded") })
        harness.events.track("works", props: nil, revenue: nil)
        harness.drainEvents()
        XCTAssertEqual(eventNames(harness), ["works"])
    }

    func testQueueDirectoryIsExcludedFromBackup() throws {
        let harness = TestHarness()
        harness.events.track("a", props: nil, revenue: nil)
        harness.drainEvents()
        let values = try harness.queueFile.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        XCTAssertEqual(QueueFileStore.live().url?.pathComponents.suffix(3), ["Application Support", "Dropplink", "dropplink-queue.json"])
    }

    // MARK: identify / logout

    func testIdentifyWithTheSameUserIsANoOpUntilLogout() throws {
        let harness = TestHarness()
        harness.events.identify(userId: "u1", email: "a@b.co", phone: nil)
        harness.events.identify(userId: " u1 ", email: "other@b.co", phone: nil) // traits included
        harness.drainEvents()
        XCTAssertEqual(harness.events.snapshot.count, 1)

        harness.events.identify(userId: "u2", email: nil, phone: nil)
        harness.events.logout()
        harness.events.identify(userId: "u2", email: nil, phone: nil)
        harness.drainEvents()
        let userIds = harness.events.snapshot.items.compactMap { item -> String?? in
            if case .identify(let identify) = item { return .some(identify.userId) }
            return nil
        }
        XCTAssertEqual(userIds, ["u1", "u2", nil, "u2"])
        XCTAssertEqual(harness.events.snapshot.lastUserId, "u2")
    }

    // MARK: setTrackingEnabled

    func testDisablingTrackingClearsTheQueueAndStopsEverythingUntilReenabled() async throws {
        let harness = try await readyHarness()
        harness.http.script("/v1/events", .status(200, Fixtures.eventsOK(accepted: 1)))
        XCTAssertTrue(harness.events.isTrackingEnabled, "default true")
        harness.events.identify(userId: "u1", email: nil, phone: nil)
        harness.events.track("a", props: nil, revenue: nil)
        harness.events.setTrackingEnabled(false)
        harness.drainEvents()

        XCTAssertFalse(harness.events.isTrackingEnabled)
        XCTAssertTrue(harness.events.snapshot.isEmpty)
        XCTAssertNil(harness.events.snapshot.lastUserId)
        XCTAssertTrue(try JSONDecoder().decode(QueueFile.self, from: Data(contentsOf: harness.queueFile)).items.isEmpty, "cleared on disk")

        harness.events.track("b", props: nil, revenue: nil)
        harness.events.identify(userId: "u1", email: nil, phone: nil)
        harness.events.logout()
        await harness.fireTimers()
        XCTAssertNil(harness.events.flush(.background))
        XCTAssertTrue(harness.events.snapshot.isEmpty)
        XCTAssertEqual(harness.paths, ["/v1/init"], "nothing sent")

        // Persisted across launches.
        let next = TestHarness(defaults: harness.defaults, queueFile: harness.queueFile)
        XCTAssertFalse(next.events.isTrackingEnabled)
        XCTAssertFalse(Storage(defaults: harness.defaults).trackingEnabled)

        harness.events.setTrackingEnabled(true)
        harness.events.track("c", props: nil, revenue: nil)
        await harness.fireTimers()
        XCTAssertEqual(harness.bodies(to: "/v1/events").map(sentNames), [["c"]], "nothing from while it was off")
        XCTAssertTrue(harness.core.installId != nil && harness.core.attribution != nil, "attribution keeps working")
    }

    func testConcurrentCallsAreSafe() async throws {
        let harness = try await readyHarness()
        harness.http.script("/v1/events", .status(200, Fixtures.eventsOK(accepted: 100)))
        harness.http.script("/v1/identify", .status(200, try Fixtures.identifyOK()))
        let events = harness.events
        DispatchQueue.concurrentPerform(iterations: 300) { i in
            switch i % 6 {
            case 0: events.identify(userId: "u\(i % 4)", email: nil, phone: nil)
            case 1: _ = events.flush(.background)
            case 2: _ = events.snapshot
            default: events.track("e\(i)", props: ["i": i], revenue: nil)
            }
        }
        harness.drainEvents()
        await harness.events.waitUntilIdle()
        await harness.events.flush(.background)?.value
        await harness.events.waitUntilIdle()
        XCTAssertTrue(harness.events.snapshot.isEmpty)
        let sent = harness.bodies(to: "/v1/events").flatMap(sentNames)
        XCTAssertEqual(sent.count, 150)
        XCTAssertEqual(Set(sent).count, 150, "each event sent once")
    }
}
