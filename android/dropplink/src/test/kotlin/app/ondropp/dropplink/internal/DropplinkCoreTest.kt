package app.ondropp.dropplink.internal

import app.ondropp.dropplink.DeepLink
import app.ondropp.dropplink.DropplinkConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import kotlin.random.Random

/** Lifecycle (spec 3), signing headers (4), retries (5, spec 10.4) and deep link delivery (7). */
class DropplinkCoreTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private val config = DropplinkConfig(keyId = "ak_3f9c1e2a7b6d4c80", secret = "s3cret", baseUrl = "https://api.test/")
    private val env = FakeEnvironment()
    private val sleeps = mutableListOf<Long>()
    private val delivered = mutableListOf<DeepLink>()
    private val logs = mutableListOf<String>()
    private val dispatcher = DeepLinkDispatcher(DirectExecutor).apply { setListener { delivered += it } }
    private val storage by lazy { Storage(tmp.root.resolve("dropplink.json")) }
    private val nowMs = 1_760_700_000_123L

    private fun core(http: HttpClient, background: java.util.concurrent.Executor = DirectExecutor) = DropplinkCore(
        config = config,
        storage = storage,
        http = http,
        environment = env,
        dispatcher = dispatcher,
        logger = Logger(enabled = true) { level, message -> logs += "$level $message" },
        background = background,
        queue = EventQueue(tmp.root.resolve("dropplink-queue.json"), Logger(enabled = false)) { nowMs / 1000 },
        io = DirectExecutor,
        scheduler = FakeScheduler().scheduler,
        retryPolicy = RetryPolicy(random = Random(42)),
        clockMs = { nowMs },
        sleep = { sleeps += it },
    )

    private val attributed get() = Contract.text("init/response.attributed.json")
    private val organic get() = Contract.text("init/response.organic.json")

    // --- Lifecycle -------------------------------------------------------------------------------------

    @Test
    fun attributedInitStoresAttributionAndDeliversDeferredLink() {
        val http = FakeHttpClient(200 to attributed)
        core(http).start()

        val request = http.requests.single()
        assertEquals("https://api.test/v1/init", request.url)
        assertEquals("c_8b1f0e7d2a4c4f6e", request.json.getJSONObject("installReferrer").getString("clickId"))

        val stored = storage.read()
        assertTrue(stored.attributed)
        assertEquals("install_referrer", stored.attribution?.method)
        assertEquals(DeepLink("/product/123", mapOf("ref" to "creator", "variant" to "red"), null, true), delivered.single())
        assertTrue(logs.any { it.contains("init 200 attributed via install_referrer, link 6711a0…, deep link /product/123") })
    }

    @Test
    fun installIdIsStableAcrossLaunchesAndReferrerStopsOnceAttributed() {
        val first = core(FakeHttpClient(200 to attributed))
        first.start()
        val id = first.installId

        val http = FakeHttpClient(200 to attributed.replace("\"deepLink\": {", "\"ignored\": {"))
        val second = core(http)
        second.start()

        assertEquals(id, second.installId)
        assertEquals(id, http.requests.single().json.getString("installId"))
        assertFalse(http.requests.single().json.has("installReferrer"))
        assertEquals(1, env.referrerReads)
        assertEquals("attributed", second.attribution?.type)
    }

    @Test
    fun organicInstallKeepsSendingTheReferrer() {
        core(FakeHttpClient(200 to organic)).start()
        val http = FakeHttpClient(200 to organic)
        core(http).start()

        assertTrue(http.requests.single().json.has("installReferrer"))
        assertEquals(2, env.referrerReads)
        assertFalse(storage.read().attributed)
        assertTrue(delivered.isEmpty())
    }

    @Test
    fun attributionIsNullBeforeTheFirstSuccessfulInit() {
        val core = core(FakeHttpClient(), background = QueueExecutor())
        core.start()
        assertNull(core.attribution)
        assertNotNull(core.installId)
    }

    // --- Signing headers -------------------------------------------------------------------------------

    @Test
    fun signsTheExactBytesSentWithASecondsTimestamp() {
        val http = FakeHttpClient(200 to organic)
        core(http).start()

        val request = http.requests.single()
        assertEquals("ak_3f9c1e2a7b6d4c80", request.headers["X-Key-Id"])
        assertEquals("1760700000", request.headers["X-Timestamp"])
        assertEquals("application/json", request.headers["Content-Type"])
        assertEquals(Signer.sign("s3cret", "1760700000", request.body), request.headers["X-Signature"])
        assertFalse(logs.any { it.contains("s3cret") || it.contains(request.headers["X-Signature"]!!) })
    }

    // --- Retries ---------------------------------------------------------------------------------------

    @Test
    fun retriesServerErrorsThreeTimesWithBackoff() {
        val http = FakeHttpClient(500 to "", 503 to "", 502 to "", 500 to "")
        core(http).start()

        assertEquals(4, http.requests.size)
        assertEquals(3, sleeps.size)
        listOf(1000L, 2000L, 4000L).forEachIndexed { i, base ->
            assertTrue("sleep $i = ${sleeps[i]}", sleeps[i] in (base * 0.8).toLong()..(base * 1.2).toLong())
        }
        assertNull(storage.read().attribution)
    }

    @Test
    fun retriesNetworkErrorsAnd429ThenSucceeds() {
        val http = FakeHttpClient(null, 429 to errorBody("rate_limited"), 200 to organic)
        core(http).start()

        assertEquals(3, http.requests.size)
        assertEquals("organic", storage.read().attribution?.type)
    }

    @Test
    fun retriesStaleTimestampAndWarnsAboutTheClock() {
        val http = FakeHttpClient(401 to errorBody("stale_timestamp"), 200 to organic)
        core(http).start()

        assertEquals(2, http.requests.size)
        assertTrue(logs.any { it.contains("Device clock looks wrong") })
    }

    @Test
    fun invalidKeyStopsEverythingThisLaunch() {
        val http = FakeHttpClient(401 to errorBody("invalid_key"))
        val core = core(http)
        core.start()
        core.handleDeepLink("https://go.brand.com/summer")

        assertEquals(1, http.requests.size)
        assertTrue(sleeps.isEmpty())
        assertTrue(logs.any { it.startsWith("ERROR") && it.contains("invalid_key") })
    }

    @Test
    fun platformMismatchStops() {
        val http = FakeHttpClient(400 to errorBody("platform_mismatch"))
        core(http).start()

        assertEquals(1, http.requests.size)
        assertTrue(logs.any { it.contains("iOS key, used in an Android app") })
    }

    @Test
    fun otherClientErrorsStopAndLogTheCode() {
        val http = FakeHttpClient(
            400 to """{"error":{"code":"validation_failed","message":"Invalid body","details":[{"path":"device","message":"Required"}]}}""",
        )
        core(http).start()

        assertEquals(1, http.requests.size)
        assertTrue(logs.any { it.contains("validation_failed") && it.contains("Invalid body") && it.contains("Required") })
    }

    @Test
    fun badSignatureIsNotRetried() {
        val http = FakeHttpClient(401 to errorBody("bad_signature"))
        core(http).start()
        assertEquals(1, http.requests.size)
    }

    // --- Deep links ------------------------------------------------------------------------------------

    @Test
    fun deepLinkIsSentAfterInitAndDelivered() {
        val background = QueueExecutor()
        val http = FakeHttpClient(200 to organic, 200 to Contract.text("deeplink/response.matched.json"))
        val core = core(http, background)
        core.start()
        core.handleDeepLink("https://go.brand.com/summer?s=ig&ref=story")
        background.runAll()

        assertEquals(listOf("https://api.test/v1/init", "https://api.test/v1/deeplink"), http.requests.map { it.url })
        val body = http.requests[1].json
        assertEquals(core.installId, body.getString("installId"))
        assertEquals("https://go.brand.com/summer?s=ig&ref=story", body.getString("url"))
        assertEquals(
            DeepLink(
                "/product/123",
                mapOf("variant" to "red", "ref" to "story"),
                "https://go.brand.com/summer?s=ig&ref=story",
                false,
            ),
            delivered.single(),
        )
    }

    @Test
    fun unmatchedDeepLinkDeliversNothing() {
        val http = FakeHttpClient(200 to organic, 200 to Contract.text("deeplink/response.none.json"))
        val core = core(http)
        core.start()
        core.handleDeepLink("https://elsewhere.com/x")

        assertEquals(2, http.requests.size)
        assertTrue(delivered.isEmpty())
    }

    @Test
    fun customRedirectOpensTheBrowserAndDeliversNothing() {
        val http = FakeHttpClient(200 to organic, 200 to Contract.text("deeplink/response.redirect.json"))
        val core = core(http)
        core.start()
        core.handleDeepLink("https://go.brand.com/w/blog")

        assertEquals("https://go.brand.com/w/blog", http.requests[1].json.getString("url"))
        assertEquals(
            listOf("https://brand.com/blog?dropp_click_id=c_3d9a0b1c2e4f6a8b&utm_source=instagram&utm_medium=link&utm_campaign=blog"),
            env.openedInBrowser,
        )
        assertTrue(delivered.isEmpty())
    }

    @Test
    fun clickWithoutDeepLinkPathDeliversNothing() {
        val http = FakeHttpClient(200 to organic, 200 to """{"clickId":"c_1","deepLink":null}""")
        val core = core(http)
        core.start()
        core.handleDeepLink("https://go.brand.com/nopath")
        assertTrue(delivered.isEmpty())
    }

    @Test
    fun nonHttpUrlsAreIgnored() {
        val http = FakeHttpClient(200 to organic)
        val core = core(http)
        core.start()
        core.handleDeepLink("myapp://product/123")
        core.handleDeepLink("intent://x")

        assertEquals(1, http.requests.size)
    }

    @Test
    fun exceptionsInBackgroundWorkNeverEscape() {
        val http = object : HttpClient {
            override fun post(url: String, headers: Map<String, String>, body: ByteArray): HttpResponse =
                throw IllegalStateException("boom")
        }
        core(http).start() // must not throw
        assertTrue(logs.any { it.contains("init failed") })
    }
}
