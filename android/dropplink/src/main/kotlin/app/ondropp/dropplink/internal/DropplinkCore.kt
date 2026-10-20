package app.ondropp.dropplink.internal

import app.ondropp.dropplink.Attribution
import app.ondropp.dropplink.DeepLink
import app.ondropp.dropplink.DropplinkConfig
import org.json.JSONObject
import java.io.IOException
import java.util.UUID
import java.util.concurrent.Executor

/**
 * The SDK's logic, free of Android types so it runs in plain JVM unit tests.
 *
 * All network work runs on [background], a single-thread executor: tasks run in submission order, so a
 * `handleDeepLink` submitted while init is still running is sent after init finishes (spec section 3).
 */
internal class DropplinkCore(
    private val config: DropplinkConfig,
    private val storage: Storage,
    private val http: HttpClient,
    private val environment: Environment,
    private val dispatcher: DeepLinkDispatcher,
    private val logger: Logger,
    private val background: Executor,
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

    val installId: String get() = state().installId!!

    val attribution: Attribution? get() = state().attribution

    /** Queues `/v1/init`. Called once per process. */
    fun start() {
        runInBackground("init") { runInit() }
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

    private fun runInit() {
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

        val response = send("/v1/init", body) ?: return
        val parsed = try {
            Responses.parseInit(response.body)
        } catch (e: Exception) {
            logger.error("init: unreadable response: $e")
            return
        }

        val attribution = parsed.attribution
        val updated = synchronized(stateLock) {
            val base = state ?: current
            base.copy(
                attributed = base.attributed || attribution.type == TYPE_ATTRIBUTED,
                attribution = attribution,
            ).also { state = it }
        }
        saveState(updated)
        logger.debug(initSummary(response.status, attribution, parsed.deepLink))

        // The server sends the deferred link at most once per install, so it is never stored.
        parsed.deepLink?.let { target ->
            dispatcher.deliver(DeepLink(target.path, target.params, url = null, isDeferred = true))
        }
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

            // A fresh timestamp per attempt, so a retry after `stale_timestamp` can succeed.
            val timestamp = (clockMs() / 1000).toString()
            val headers = mapOf(
                "Content-Type" to "application/json",
                "X-Key-Id" to config.keyId,
                "X-Timestamp" to timestamp,
                "X-Signature" to Signer.sign(config.secret, timestamp, body),
            )

            val response = try {
                http.post(baseUrl + path, headers, body)
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

        fun isHttpUrl(url: String): Boolean =
            url.startsWith("https://", ignoreCase = true) || url.startsWith("http://", ignoreCase = true)
    }
}
