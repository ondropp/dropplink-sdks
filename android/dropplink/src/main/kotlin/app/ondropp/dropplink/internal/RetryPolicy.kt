package app.ondropp.dropplink.internal

import kotlin.random.Random

/** Spec section 5: which responses are worth retrying, and how long to wait between tries. */
internal class RetryPolicy(
    val maxRetries: Int = 3,
    private val baseDelayMs: Long = 1_000,
    private val random: Random = Random.Default,
) {
    enum class Action { SUCCESS, RETRY, STOP }

    /**
     * @param status HTTP status, or `null` for a network error / timeout.
     * @param errorCode `error.code` from the error body, if any.
     */
    fun decide(status: Int?, errorCode: String?): Action = when {
        status == null -> Action.RETRY
        status in 200..299 -> Action.SUCCESS
        status == 429 || status in 500..599 -> Action.RETRY
        // A wrong device clock can be fixed by the user (or NTP) mid-session; every other 401 can't.
        status == 401 && errorCode == "stale_timestamp" -> Action.RETRY
        else -> Action.STOP
    }

    /** Delay before retry number [retry] (1-based): 1 s, 2 s, 4 s, each ± 20 % jitter. */
    fun delayMs(retry: Int): Long {
        val base = baseDelayMs shl (retry - 1)
        val jitter = 0.8 + random.nextDouble() * 0.4
        return (base * jitter).toLong()
    }
}
