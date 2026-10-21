package app.ondropp.dropplink.internal

import app.ondropp.dropplink.DropplinkConfig
import app.ondropp.dropplink.Revenue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import kotlin.random.Random

/**
 * Spec section 10.7: when the queue is sent and what each response does (section 11), ordering of identify
 * before later events, persistence across a restart, and setTrackingEnabled(false).
 */
class EventsCoreTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private val config = DropplinkConfig(keyId = "ak_3f9c1e2a7b6d4c80", secret = "s3cret", baseUrl = "https://api.test")
    private val time = FakeScheduler()
    private val startMs = 1_760_700_000_000L
    private val nowMs get() = startMs + time.nowMs
    private val logs = mutableListOf<String>()
    private val storage by lazy { Storage(tmp.root.resolve("dropplink.json")) }
    private val queueFile by lazy { tmp.root.resolve("dropplink-queue.json") }
    private val organic get() = Contract.text("init/response.organic.json")
    private val eventsOk = """{"accepted":1,"duplicates":0,"rejected":[],"warnings":[]}"""
    private val identifyOk = """{"installId":"x","userId":"user_8812"}"""

    private fun core(http: HttpClient, background: java.util.concurrent.Executor = DirectExecutor): DropplinkCore {
        val logger = Logger(enabled = true) { level, message -> logs += "$level $message" }
        return DropplinkCore(
            config = config,
            storage = storage,
            http = http,
            environment = FakeEnvironment(),
            dispatcher = DeepLinkDispatcher(DirectExecutor),
            logger = logger,
            background = background,
            queue = EventQueue(queueFile, logger) { nowMs / 1000 },
            io = DirectExecutor,
            scheduler = time.scheduler,
            retryPolicy = RetryPolicy(random = Random(7)),
            clockMs = { nowMs },
            sleep = {},
        )
    }

    /** A started core whose init succeeded with an empty queue. */
    private fun started(http: FakeHttpClient): DropplinkCore {
        http.enqueue(200, organic)
        return core(http).also { it.start() }
    }

    private val FakeHttpClient.paths get() = requests.map { it.url.removePrefix("https://api.test") }
    private fun FakeHttpClient.eventNames(i: Int): List<String> {
        val events = requests[i].json.getJSONArray("events")
        return (0 until events.length()).map { events.getJSONObject(it).getString("name") }
    }
    private fun queued() = EventQueue(queueFile, Logger(false)) { nowMs / 1000 }.items()

    // --- When it sends ---------------------------------------------------------------------------------

    @Test
    fun trackIsSentOneSecondAfterTheLastCall() {
        val http = FakeHttpClient()
        val core = started(http)
        core.track("add_to_cart", mapOf("sku" to "TSHIRT-M"), null)
        time.advance(900)
        core.track("add_to_cart", mapOf("sku" to "CAP"), null)
        time.advance(900)
        assertEquals(listOf("/v1/init"), http.paths)

        http.enqueue(200, eventsOk)
        time.advance(100)
        assertEquals(listOf("/v1/init", "/v1/events"), http.paths)
        val body = http.requests[1].json
        assertEquals(core.installId, body.getString("installId"))
        assertEquals(2, body.getJSONArray("events").length())
        assertEquals(Signer.sign("s3cret", http.requests[1].headers["X-Timestamp"]!!, http.requests[1].body), http.requests[1].headers["X-Signature"])
        assertTrue(queued().isEmpty())
        assertTrue(logs.any { it.contains("track add_to_cart (queued, 2 waiting)") })
        assertTrue(logs.any { it.contains("events 200: 1 accepted, 0 duplicates, 0 rejected") })
    }

    @Test
    fun eventIdAndTsAreFixedWhenTrackIsCalled() {
        val http = FakeHttpClient()
        val core = started(http)
        core.track("purchase", null, Revenue(499.0, "INR", "A1023"))
        val stored = queued().single() as QueueItem.Event
        assertEquals(nowMs / 1000, stored.ts)

        http.enqueue(503, errorBody("storage_unavailable"))
        time.advance(1000)
        http.enqueue(200, eventsOk)
        time.advance(time.pendingDelays.single())

        val sent = http.requests.drop(1).map { it.json.getJSONArray("events").getJSONObject(0) }
        assertEquals(2, sent.size)
        sent.forEach {
            assertEquals(stored.eventId, it.getString("eventId"))
            assertEquals(stored.ts, it.getLong("ts"))
        }
    }

    @Test
    fun nothingIsSentBeforeInitSucceeds() {
        val background = QueueExecutor()
        val http = FakeHttpClient(200 to organic, 200 to eventsOk)
        val core = core(http, background)
        core.start()
        core.track("app_open", null, null)
        time.advance(5000)
        core.onBackground()
        assertTrue(http.requests.isEmpty())

        // Init runs first and flushes; the later background flush finds the queue empty.
        background.runAll()
        assertEquals(listOf("/v1/init", "/v1/events"), http.paths)
    }

    @Test
    fun nothingIsSentWhenInitFailedThisLaunch() {
        val http = FakeHttpClient(400 to errorBody("validation_failed"))
        val core = core(http)
        core.start()
        core.track("app_open", null, null)
        time.advance(1000)
        core.onBackground()
        assertEquals(1, http.requests.size)
        assertEquals(1, queued().size)
    }

    @Test
    fun goingToTheBackgroundFlushesAtOnce() {
        val http = FakeHttpClient()
        val core = started(http)
        core.track("app_open", null, null)
        http.enqueue(200, eventsOk)
        core.onBackground()
        assertEquals(listOf("/v1/init", "/v1/events"), http.paths)
    }

    @Test
    fun persistsAcrossARestartAndSendsAfterTheNextInit() {
        // First launch: init never gets to run (the process is killed).
        val first = core(FakeHttpClient(), background = QueueExecutor())
        first.track("add_to_cart", mapOf("qty" to 1), null)
        first.identify("user_8812", null, null)
        first.track("purchase", null, Revenue(10.0, "USD"))
        val eventId = (queued().first() as QueueItem.Event).eventId

        val http = FakeHttpClient(200 to organic, 200 to eventsOk, 200 to identifyOk, 200 to eventsOk)
        core(http).start()
        assertEquals(listOf("/v1/init", "/v1/events", "/v1/identify", "/v1/events"), http.paths)
        assertEquals(eventId, http.requests[1].json.getJSONArray("events").getJSONObject(0).getString("eventId"))
        assertTrue(queued().isEmpty())
    }

    // --- Ordering and identify -------------------------------------------------------------------------

    @Test
    fun identifyIsSentAloneAndBeforeTheEventsTrackedAfterIt() {
        val http = FakeHttpClient()
        val core = started(http)
        core.track("view_item", null, null)
        core.identify("user_8812", "priya@example.com", null)
        core.track("add_to_cart", null, null)
        core.logout()
        core.track("app_close", null, null)

        http.enqueue(200, eventsOk)
        http.enqueue(200, identifyOk)
        http.enqueue(200, eventsOk)
        http.enqueue(200, """{"installId":"x","userId":null}""")
        http.enqueue(200, eventsOk)
        time.advance(1000)

        assertEquals(listOf("/v1/init", "/v1/events", "/v1/identify", "/v1/events", "/v1/identify", "/v1/events"), http.paths)
        assertEquals(listOf("view_item"), http.eventNames(1))
        assertEquals("user_8812", http.requests[2].json.getString("userId"))
        assertEquals(Signer.sha256Hex("priya@example.com".toByteArray()), http.requests[2].json.getJSONObject("traits").getString("emailHash"))
        assertEquals(listOf("add_to_cart"), http.eventNames(3))
        assertTrue(http.requests[4].json.isNull("userId"))
        assertEquals(listOf("app_close"), http.eventNames(5))
        assertTrue(logs.any { it.contains("identify user_8812 sent") })
        assertFalse("hashes and emails are never logged", logs.any { it.contains("priya") || it.contains(Signer.sha256Hex("priya@example.com".toByteArray())) })
    }

    @Test
    fun identifyWithTheSameUserIdIsANoOpUntilLogout() {
        val http = FakeHttpClient()
        val core = started(http)
        core.identify("user_8812", null, null)
        core.identify(" user_8812 ", "priya@example.com", null)
        assertEquals(1, queued().size)

        http.enqueue(200, identifyOk)
        time.advance(1000)
        core.identify("user_8812", null, null) // Same as the last one sent.
        assertTrue(queued().isEmpty())

        core.logout()
        core.identify("user_8812", null, null)
        assertEquals(2, queued().size)
    }

    @Test
    fun invalidCallsAreNotQueued() {
        val core = started(FakeHttpClient())
        core.track("Add To Cart", null, null)
        core.identify("priya@example.com", null, null)
        assertTrue(queued().isEmpty())
        assertTrue(logs.any { it.contains("event \"Add To Cart\" dropped: name must be snake_case, e.g. add_to_cart") })
    }

    // --- Response table --------------------------------------------------------------------------------

    @Test
    fun okRemovesAcceptedDuplicatesAndRejectedAndLogsThem() {
        val http = FakeHttpClient()
        val core = started(http)
        core.track("add_to_cart", null, null)
        core.track("purchase", null, null)
        http.enqueue(200, Contract.text("events/response.partial.json"))
        time.advance(1000)

        assertTrue(queued().isEmpty())
        assertTrue(logs.any { it.contains("events 200: 1 accepted, 0 duplicates, 1 rejected") })
        assertTrue(logs.any { it.contains("rejected: too_old") })
        assertTrue(logs.any { it.contains("pii_in_props") && it.contains("email") })
    }

    @Test
    fun serverErrorsAndNetworkErrorsBackOffExponentiallyAndKeepEverything() {
        val http = FakeHttpClient()
        val core = started(http)
        core.track("app_open", null, null)
        http.enqueue(503, errorBody("storage_unavailable"))
        http.enqueueNetworkError()
        http.enqueue(429, errorBody("rate_limited"))
        http.enqueue(500, "")
        time.advance(1000)

        val delays = mutableListOf<Long>()
        repeat(3) {
            val delay = time.pendingDelays.single()
            delays += delay
            assertEquals(1, queued().size)
            time.advance(delay)
        }
        listOf(1000L, 2000L, 4000L).forEachIndexed { i, base ->
            assertTrue("delay $i = ${delays[i]}", delays[i] in (base * 0.8).toLong()..(base * 1.2).toLong())
        }
        assertEquals(5, http.requests.size)

        // The backoff resets after a 200.
        http.enqueue(200, eventsOk)
        time.advance(time.pendingDelays.single())
        assertTrue(queued().isEmpty())
        core.track("app_close", null, null)
        http.enqueue(503, "")
        time.advance(1000)
        assertTrue(time.pendingDelays.single() in 800L..1200L)
    }

    @Test
    fun debouncedFlushesWaitForAPendingBackoff() {
        val http = FakeHttpClient()
        val core = started(http)
        core.track("a", null, null)
        http.enqueue(503, "", mapOf("Retry-After" to "30"))
        time.advance(1000)
        val retryIn = time.pendingDelays.single()
        assertEquals(30_000L, retryIn)

        core.track("b", null, null)
        core.onBackground()
        time.advance(1000)
        assertEquals(2, http.requests.size)

        http.enqueue(200, eventsOk)
        time.advance(retryIn)
        assertEquals(listOf("a", "b"), http.eventNames(2))
    }

    @Test
    fun aLongerRetryAfterWins() {
        val http = FakeHttpClient()
        val core = started(http)
        core.track("app_open", null, null)
        http.enqueue(429, errorBody("rate_limited"), mapOf("retry-after" to "30"))
        time.advance(1000)
        assertEquals(30_000L, time.pendingDelays.single())
    }

    @Test
    fun backoffIsCappedAtFiveMinutes() {
        val policy = RetryPolicy(random = Random(1))
        assertTrue(policy.queueDelayMs(9) in 204_800L..307_200L) // 256 s
        assertTrue(policy.queueDelayMs(10) in 240_000L..360_000L) // 512 s, capped at 300 s
        assertTrue(policy.queueDelayMs(60) in 240_000L..360_000L)
        assertEquals(600_000L, policy.queueDelayMs(60, retryAfterSec = 600))
        assertTrue(policy.queueDelayMs(1, retryAfterSec = 0) in 800L..1200L)
    }

    @Test
    fun staleTimestampBacksOffAndWarnsAboutTheClock() {
        val http = FakeHttpClient()
        val core = started(http)
        core.track("app_open", null, null)
        http.enqueue(401, errorBody("stale_timestamp"))
        time.advance(1000)

        assertEquals(1, time.pendingDelays.size)
        assertEquals(1, queued().size)
        assertTrue(logs.any { it.contains("Device clock looks wrong") })
    }

    @Test
    fun otherUnauthorizedPausesTheQueueUntilNextLaunch() {
        val http = FakeHttpClient()
        val core = started(http)
        core.track("app_open", null, null)
        http.enqueue(401, errorBody("bad_signature"))
        time.advance(1000)
        core.track("app_close", null, null)
        time.advance(1000)
        core.onBackground()

        assertEquals(2, http.requests.size)
        assertTrue(time.pendingDelays.isEmpty())
        assertEquals(2, queued().size)
        assertTrue(logs.any { it.startsWith("ERROR") && it.contains("bad_signature") })

        // Next launch sends everything.
        val next = FakeHttpClient(200 to organic, 200 to eventsOk)
        core(next).start()
        assertEquals(listOf("app_open", "app_close"), next.eventNames(1))
    }

    @Test
    fun unknownInstallRunsInitAgainThenRetries() {
        val http = FakeHttpClient()
        val core = started(http)
        core.track("app_open", null, null)
        http.enqueue(404, errorBody("unknown_install"))
        http.enqueue(200, organic)
        http.enqueue(200, eventsOk)
        time.advance(1000)

        assertEquals(listOf("/v1/init", "/v1/events", "/v1/init", "/v1/events"), http.paths)
        assertTrue(queued().isEmpty())
    }

    @Test
    fun unknownInstallBacksOffWhenTheNewInitFails() {
        val http = FakeHttpClient()
        val core = started(http)
        core.track("app_open", null, null)
        http.enqueue(404, errorBody("unknown_install"))
        http.enqueue(400, errorBody("validation_failed"))
        time.advance(1000)

        assertEquals(listOf("/v1/init", "/v1/events", "/v1/init"), http.paths)
        assertEquals(1, time.pendingDelays.size)
        assertEquals(1, queued().size)
    }

    @Test
    fun badRequestDropsThatBatchAndCarriesOn() {
        val http = FakeHttpClient()
        val core = started(http)
        core.identify("user_8812", null, null)
        core.track("app_open", null, null)
        http.enqueue(400, errorBody("pii_in_user_id", "userId looks like an email"))
        http.enqueue(200, eventsOk)
        time.advance(1000)

        assertEquals(listOf("/v1/init", "/v1/identify", "/v1/events"), http.paths)
        assertTrue(queued().isEmpty())
        assertTrue(logs.any { it.contains("pii_in_user_id") })
    }

    @Test
    fun otherClientErrorsDropTheBatchSoTheQueueDoesntJam() {
        val http = FakeHttpClient()
        val core = started(http)
        core.track("app_open", null, null)
        http.enqueue(413, errorBody("fst_err_ctp_body_too_large"))
        time.advance(1000)
        core.track("add_to_cart", null, null)
        http.enqueue(200, eventsOk)
        time.advance(1000)

        assertEquals(listOf("/v1/init", "/v1/events", "/v1/events"), http.paths)
        assertTrue(queued().isEmpty())
    }

    // --- setTrackingEnabled ----------------------------------------------------------------------------

    @Test
    fun disablingTrackingClearsTheQueueAndPersists() {
        val http = FakeHttpClient()
        val core = started(http)
        core.identify("user_8812", null, null)
        core.track("app_open", null, null)
        core.setTrackingEnabled(false)

        assertTrue(queued().isEmpty())
        assertNull(EventQueue(queueFile, Logger(false)) { nowMs / 1000 }.lastUserId())
        assertFalse(storage.read().trackingEnabled)
        assertFalse(core.isTrackingEnabled)

        core.track("app_close", null, null)
        core.identify("user_9", null, null)
        core.logout()
        time.advance(5000)
        core.onBackground()
        assertTrue(queued().isEmpty())
        assertEquals(listOf("/v1/init"), http.paths)

        // Persisted: the next launch still has tracking off, but init (attribution) still runs.
        val next = FakeHttpClient(200 to organic)
        val restarted = core(next)
        restarted.start()
        assertFalse(restarted.isTrackingEnabled)
        restarted.track("app_open", null, null)
        assertTrue(queued().isEmpty())
        assertEquals(listOf("/v1/init"), next.paths)
        assertEquals("organic", storage.read().attribution?.type)
        assertFalse("init must not undo the setting", storage.read().trackingEnabled)

        // Turning it back on resumes, and identify isn't deduplicated against the forgotten user.
        restarted.setTrackingEnabled(true)
        assertTrue(storage.read().trackingEnabled)
        restarted.identify("user_8812", null, null)
        next.enqueue(200, identifyOk)
        time.advance(1000)
        assertEquals(listOf("/v1/init", "/v1/identify"), next.paths)
    }
}
