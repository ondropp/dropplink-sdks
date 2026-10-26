package app.ondropp.dropplink.internal

import app.ondropp.dropplink.Attribution
import app.ondropp.dropplink.DeepLink
import app.ondropp.dropplink.DropplinkConfig
import app.ondropp.dropplink.Revenue
import org.json.JSONObject
import java.io.IOException
import java.util.UUID
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicLong

/**
 * The SDK's logic, free of Android types so it runs in plain JVM unit tests.
 *
 * All network work runs on [background], a single-thread executor: tasks run in submission order, so a
 * `handleDeepLink` submitted while init is still running is sent after init finishes (spec section 3).
 * Queue flushes run there too, so there is only ever one at a time.
 *
 * `track` / `identify` / `logout` write to the [queue] on [io], a second single-thread executor, so an
 * event reaches the disk at once even while init holds the network thread (spec section 11).
 */
internal class DropplinkCore(
    private val config: DropplinkConfig,
    private val storage: Storage,
    private val http: HttpClient,
    private val environment: Environment,
    private val dispatcher: DeepLinkDispatcher,
    private val logger: Logger,
    private val background: Executor,
    private val queue: EventQueue,
    private val io: Executor,
    private val scheduler: Scheduler,
    private val retryPolicy: RetryPolicy = RetryPolicy(),
    private val clockMs: () -> Long = System::currentTimeMillis,
    private val sleep: (Long) -> Unit = Thread::sleep,
) {
    private val baseUrl = config.baseUrl.trimEnd('/')
    private val sdkVersion = sdkVersionFor(config.platformWrapper)

    private val stateLock = Any()
    private var state: Storage.State? = null

    /** Set after `invalid_key` / `platform_mismatch`: nothing this launch can succeed, so stop sending. */
    @Volatile
    private var stopped = false

    /** The queue is never sent before this launch's init has succeeded: the server must know the install. */
    @Volatile
    private var initSucceeded = false

    /** Set after a 401 other than `stale_timestamp` on the queue: no more queue requests this launch. */
    @Volatile
    private var queuePaused = false

    // Only touched on the background thread.
    private var flushing = false
    private var retryScheduled = false
    private var failures = 0

    private val debounceGeneration = AtomicLong()

    val installId: String get() = state().installId!!

    val attribution: Attribution? get() = state().attribution

    val isTrackingEnabled: Boolean get() = state().trackingEnabled

    /** Queues `/v1/init`, then a flush of whatever earlier launches left in the queue. Called once per process. */
    fun start() {
        runInBackground("init") { if (runInit()) flush() }
    }

    /** @param atMs When the app called `track`; the event's `ts` (seconds). */
    fun track(name: String, props: Map<String, Any?>?, revenue: Revenue?, atMs: Long = clockMs()) {
        if (!isTrackingEnabled) {
            logger.debug("track $name ignored: tracking is disabled")
            return
        }
        val event = EventValidation.event(name, props, revenue, UUID.randomUUID().toString(), atMs / 1000, logger)
            ?: return
        runOnIo("track") {
            val waiting = queue.add(event)
            logger.debug("track ${event.name} (queued, $waiting waiting)")
            scheduleFlush()
        }
    }

    fun identify(userId: String, email: String?, phone: String?) {
        if (!isTrackingEnabled) {
            logger.debug("identify ignored: tracking is disabled")
            return
        }
        val item = EventValidation.identify(userId, email, phone, logger) ?: return
        runOnIo("identify") {
            // Brands may call identify on every launch; the server allows 5 a minute per install.
            if (item.userId == queue.lastUserId()) {
                logger.debug("identify ${item.userId}: already identified, skipped")
                return@runOnIo
            }
            queue.add(item)
            logger.debug("identify ${item.userId} (queued)")
            scheduleFlush()
        }
    }

    fun logout() {
        if (!isTrackingEnabled) {
            logger.debug("logout ignored: tracking is disabled")
            return
        }
        runOnIo("logout") {
            queue.add(QueueItem.Identify(userId = null))
            logger.debug("logout (queued)")
            scheduleFlush()
        }
    }

    /** `false` empties the queue and stops events and identify; persisted. Init and deep links carry on. */
    fun setTrackingEnabled(enabled: Boolean) {
        synchronized(stateLock) { state = state().copy(trackingEnabled = enabled) }
        runOnIo("setTrackingEnabled") {
            synchronized(stateLock) { state?.let(::saveState) }
            if (!enabled) queue.clear()
        }
        logger.debug(if (enabled) "tracking enabled" else "tracking disabled; queue cleared")
    }

    /** The app went to the background: send what's waiting while the process is still alive. */
    fun onBackground() {
        runInBackground("flush") { flush() }
    }

    fun handleDeepLink(url: String) {
        if (!isHttpUrl(url)) {
            logger.debug("Ignoring non-http(s) deep link")
            return
        }
        if (url.length > MAX_URL_LENGTH) {
            logger.warn("Ignoring deep link longer than $MAX_URL_LENGTH characters")
            return
        }
        runInBackground("deeplink") { runDeepLink(url) }
    }

    // State is loaded on first use, from whichever thread asks first. It's a tiny file, and loading it
    // lazily lets getInstallId() answer right after initialize() instead of returning null.
    private fun state(): Storage.State = synchronized(stateLock) {
        state ?: loadState().also { state = it }
    }

    private fun loadState(): Storage.State {
        val stored = storage.read()
        if (stored.installId != null) return stored
        val created = stored.copy(installId = UUID.randomUUID().toString())
        saveState(created)
        return created
    }

    private fun saveState(newState: Storage.State) {
        try {
            storage.write(newState)
        } catch (e: IOException) {
            logger.error("Could not save state: $e")
        }
    }

    /** `true` when the server answered 200. */
    private fun runInit(): Boolean {
        val current = state()
        logger.debug("install id ${current.installId} (paste into Dropplink → Install debugger)")

        // Keep sending the referrer until the server says "attributed": an install that was organic for
        // lack of a referrer is upgraded once a later init brings a click_id.
        val referrer = if (current.attributed) null else environment.readInstallReferrer()
        val body = InitBody.build(
            installId = current.installId!!,
            appVersion = environment.appVersion,
            sdkVersion = sdkVersion,
            device = environment.deviceInfo(),
            installReferrer = referrer,
        )

        val response = send("/v1/init", body) ?: return false
        val parsed = try {
            Responses.parseInit(response.body)
        } catch (e: Exception) {
            logger.error("init: unreadable response: $e")
            return false
        }

        val attribution = parsed.attribution
        // Saved under the lock so this write can't land after (and undo) a newer setTrackingEnabled one.
        synchronized(stateLock) {
            val base = state ?: current
            base.copy(
                attributed = base.attributed || attribution.type == TYPE_ATTRIBUTED,
                attribution = attribution,
            ).also {
                state = it
                saveState(it)
            }
        }
        initSucceeded = true
        logger.debug(initSummary(response.status, attribution, parsed.deepLink))

        // The server sends the deferred link at most once per install, so it is never stored.
        parsed.deepLink?.let { target ->
            dispatcher.deliver(DeepLink(target.path, target.params, url = null, isDeferred = true))
        }
        return true
    }

    private fun runDeepLink(url: String) {
        val body = JSONObject().put("installId", installId).put("url", url)
        val response = send("/v1/deeplink", body) ?: return
        val parsed = try {
            Responses.parseDeepLink(response.body)
        } catch (e: Exception) {
            logger.error("deeplink: unreadable response: $e")
            return
        }
        parsed.redirectUrl?.let { redirect ->
            // A custom-redirect link the OS opened the app with anyway (Android 11 and older ignore the
            // intent filter's path pattern). It goes to the browser, and the listener gets nothing.
            val opened = environment.openInBrowser(redirect)
            logger.debug(if (opened) "deeplink: custom redirect opened in the browser" else "deeplink: no browser for the custom redirect")
            return
        }
        val target = parsed.deepLink
        if (target == null) {
            // clickId null: not one of this app's links. clickId set: the link has no deep link path.
            logger.debug(if (parsed.clickId == null) "deeplink: not a Dropplink link" else "deeplink: no path for this link")
            return
        }
        logger.debug("deeplink ${response.status}, deep link ${target.path}")
        dispatcher.deliver(DeepLink(target.path, target.params, url = url, isDeferred = false))
    }

    /**
     * Signs and POSTs [json], retrying per spec section 5. Returns the 2xx response, or `null` when the
     * request failed for good this launch.
     */
    private fun send(path: String, json: JSONObject): HttpResponse? {
        if (stopped) return null
        val name = path.removePrefix("/v1/")
        // Serialize once; every attempt sends (and signs) exactly these bytes.
        val body = json.toString().toByteArray(Charsets.UTF_8)

        for (attempt in 0..retryPolicy.maxRetries) {
            if (attempt > 0) sleep(retryPolicy.delayMs(attempt))

            val response = try {
                post(path, body)
            } catch (e: IOException) {
                logger.warn("$name: network error: ${e.message ?: e.javaClass.simpleName}")
                null
            }
            val error = response?.takeIf { it.status >= 400 }?.let { Responses.parseError(it.body) }

            when (retryPolicy.decide(response?.status, error?.code)) {
                RetryPolicy.Action.SUCCESS -> return response
                RetryPolicy.Action.RETRY -> {
                    if (response != null) logRetryable(name, response.status, error)
                }
                RetryPolicy.Action.STOP -> {
                    logStop(name, response!!.status, error)
                    return null
                }
            }
        }
        logger.warn("$name: giving up after ${retryPolicy.maxRetries} retries; will try again next launch")
        return null
    }

    /** One signed POST. A fresh timestamp per attempt, so a retry after `stale_timestamp` can succeed. */
    @Throws(IOException::class)
    private fun post(path: String, body: ByteArray): HttpResponse {
        val timestamp = (clockMs() / 1000).toString()
        val headers = mapOf(
            "Content-Type" to "application/json",
            "X-Key-Id" to config.keyId,
            "X-Timestamp" to timestamp,
            "X-Signature" to Signer.sign(config.secret, timestamp, body),
        )
        return http.post(baseUrl + path, headers, body)
    }

    // --- Event queue (spec section 11) ----------------------------------------------------------------

    /** 1 s after the last `track` / `identify`: each call pushes the flush back. */
    private fun scheduleFlush() {
        val generation = debounceGeneration.incrementAndGet()
        try {
            scheduler.schedule(DEBOUNCE_MS) {
                if (debounceGeneration.get() == generation) runInBackground("flush") { flush() }
            }
        } catch (t: Throwable) {
            logger.error("flush not scheduled: $t")
        }
    }

    private fun canSendQueue(): Boolean = initSucceeded && !stopped && !queuePaused && isTrackingEnabled

    /** Runs on the background thread. While a backoff is pending, only its timer flushes. */
    private fun flush() {
        if (flushing || retryScheduled || !canSendQueue()) return
        flushing = true
        try {
            flushQueue()
        } finally {
            flushing = false
        }
    }

    /** Sends batches from the head of the queue until it's empty or a request fails (the response table). */
    private fun flushQueue() {
        queue.prune()
        var reinitialized = false
        while (canSendQueue()) {
            val batch = queue.nextBatch(installId) ?: return
            val name = batch.path.removePrefix("/v1/")
            val response = try {
                post(batch.path, batch.body)
            } catch (e: IOException) {
                backOff("$name: network error: ${e.message ?: e.javaClass.simpleName}", null)
                return
            }
            val status = response.status
            val error = if (status >= 400) Responses.parseError(response.body) else null
            when {
                status in 200..299 -> {
                    failures = 0
                    logSent(batch, response)
                    queue.remove(batch.items)
                }
                status == 429 || status >= 500 -> {
                    backOff("$name: $status${error?.let { " ${it.code}" } ?: ""}", response)
                    return
                }
                status == 401 && error?.code == "stale_timestamp" -> {
                    backOff("$name: 401 stale_timestamp. Device clock looks wrong", response)
                    return
                }
                status == 401 -> {
                    queuePaused = true
                    logStop(name, status, error)
                    logger.error("$name: events and identify are paused until the next launch; nothing is lost")
                    return
                }
                status == 404 && error?.code == "unknown_install" && !reinitialized -> {
                    // The server lost (or never stored) this install: register it again, then retry.
                    logger.warn("$name: 404 unknown_install; running init again")
                    reinitialized = true
                    if (!runInit()) {
                        backOff("$name: init failed", null)
                        return
                    }
                }
                status == 404 && error?.code == "unknown_install" -> {
                    backOff("$name: 404 unknown_install after a new init", response)
                    return
                }
                status in 400..499 -> {
                    // 400 and any other 4xx (413, 403, …): a malformed batch (an SDK bug) or a refused
                    // identify. Retrying won't help, and keeping it would block everything behind it.
                    logStop(name, status, error)
                    logger.warn("$name: dropped ${batch.items.size} queued ${if (name == "identify") "identify" else "events"}")
                    queue.remove(batch.items)
                }
                else -> {
                    // Anything else (a redirect, say) is a server or network setup problem, not the batch's.
                    backOff("$name: unexpected $status", response)
                    return
                }
            }
        }
    }

    /** Keeps everything and tries again later: 1 s, 2 s, 4 s … 5 min, or the server's longer `Retry-After`. */
    private fun backOff(reason: String, response: HttpResponse?) {
        failures++
        val retryAfterSec = response?.header("Retry-After")?.trim()?.toLongOrNull()
        val delayMs = retryPolicy.queueDelayMs(failures, retryAfterSec)
        logger.warn("$reason; retrying in ${delayMs / 1000.0} s")
        retryScheduled = true
        try {
            scheduler.schedule(delayMs) {
                runInBackground("flush") {
                    retryScheduled = false
                    flush()
                }
            }
        } catch (t: Throwable) {
            retryScheduled = false
            logger.error("retry not scheduled: $t")
        }
    }

    private fun logSent(batch: Batch, response: HttpResponse) {
        val identify = batch.items.singleOrNull() as? QueueItem.Identify
        if (identify != null) {
            logger.debug(if (identify.userId == null) "logout sent" else "identify ${identify.userId} sent")
            return
        }
        val parsed = try {
            Responses.parseEvents(response.body)
        } catch (e: Exception) {
            logger.warn("events ${response.status}: unreadable response: $e")
            return
        }
        logger.debug(
            "events ${response.status}: ${parsed.accepted} accepted, ${parsed.duplicates} duplicates, " +
                "${parsed.rejected.size} rejected",
        )
        parsed.rejected.forEach { logger.warn("event ${it.eventId ?: "#${it.index}"} rejected: ${it.code}: ${it.message}") }
        parsed.warnings.forEach {
            logger.warn("event ${it.eventId}: ${it.code}, server dropped props ${it.props.joinToString(", ")}")
        }
    }

    private fun logRetryable(name: String, status: Int, error: ApiError?) {
        if (error?.code == "stale_timestamp") {
            logger.warn("$name: 401 stale_timestamp. Device clock looks wrong; retrying")
        } else {
            logger.warn("$name: $status${error?.let { " ${it.code}" } ?: ""}; retrying")
        }
    }

    private fun logStop(name: String, status: Int, error: ApiError?) {
        when (error?.code) {
            "invalid_key" -> {
                stopped = true
                logger.error(
                    "$name: 401 invalid_key. The key id ${config.keyId} is unknown or revoked, or its app was " +
                        "deleted. Check keyId and secret against the dashboard. Dropplink is off until next launch.",
                )
            }
            "platform_mismatch" -> {
                stopped = true
                logger.error(
                    "$name: 400 platform_mismatch. This is an iOS key, used in an Android app. " +
                        "Use the Android SDK key from the dashboard.",
                )
            }
            else -> logger.error(
                "$name: $status ${error?.code ?: "(no error code)"}: ${error?.message.orEmpty()}" +
                    (error?.details?.let { " details=$it" } ?: ""),
            )
        }
    }

    private fun initSummary(status: Int, attribution: Attribution, deepLink: DeepLinkTarget?): String = buildString {
        append("init ").append(status).append(' ').append(attribution.type)
        append(" via ").append(attribution.method)
        attribution.linkId?.let { append(", link ").append(it.take(6)).append('…') }
        deepLink?.let { append(", deep link ").append(it.path) }
    }

    private fun runOnIo(name: String, task: () -> Unit) {
        try {
            io.execute {
                try {
                    task()
                } catch (t: Throwable) {
                    logger.error("$name failed: $t")
                }
            }
        } catch (t: Throwable) {
            logger.error("$name not scheduled: $t")
        }
    }

    private fun runInBackground(name: String, task: () -> Unit) {
        try {
            background.execute {
                try {
                    task()
                } catch (t: Throwable) {
                    // Rule 1: never crash the host app.
                    logger.error("$name failed: $t")
                }
            }
        } catch (t: Throwable) {
            logger.error("$name not scheduled: $t")
        }
    }

    companion object {
        private const val TYPE_ATTRIBUTED = "attributed"
        private const val MAX_URL_LENGTH = 2048
        private const val DEBOUNCE_MS = 1_000L

        fun isHttpUrl(url: String): Boolean =
            url.startsWith("https://", ignoreCase = true) || url.startsWith("http://", ignoreCase = true)
    }
}
