package app.ondropp.dropplink.internal

import app.ondropp.dropplink.Revenue
import java.math.BigDecimal
import java.math.RoundingMode
import java.util.Locale

/**
 * The server's personal-data checks (`src/lib/pii.ts`), ported exactly. They catch mistakes, not
 * determined misuse.
 *
 * JavaScript's `\s` also matches Unicode spaces that Java's doesn't, so they are listed explicitly.
 */
internal object Pii {
    private const val WS = "\\s\\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF"
    private val EMAIL = Regex("[^$WS@]+@[^$WS@]+\\.[^$WS@]{2,}")
    private val SEPARATORS = Regex("[$WS().-]")
    private val INTERNATIONAL = Regex("^\\+\\d{10,15}$")
    private val INDIAN_MOBILE = Regex("^(?:0|91)?[6-9]\\d{9}$")

    /** An email anywhere in the value. */
    fun looksLikeEmail(value: String): Boolean = EMAIL.containsMatchIn(value)

    /** The whole value is a phone number: international, or an Indian mobile. */
    fun looksLikePhone(value: String): Boolean {
        val compact = value.replace(SEPARATORS, "")
        return INTERNATIONAL.matches(compact) || INDIAN_MOBILE.matches(compact)
    }

    fun isPersonal(value: String): Boolean = looksLikeEmail(value) || looksLikePhone(value)

    /** Spaces, `(`, `)`, `.` and `-` removed: the form a phone is checked (and hashed) in. */
    fun compactPhone(value: String): String = value.replace(SEPARATORS, "")
}

/**
 * Local checks for `track` and `identify` (spec section 11), so the server never has to reject what the
 * SDK could have caught. Problems are logged in debug mode, never with prop values, emails or phones.
 */
internal object EventValidation {
    const val MAX_PROPS = 20
    const val MAX_STRING = 256
    private const val MAX_ORDER_ID = 128
    private const val MAX_USER_ID = 128

    private val NAME = Regex("^[a-z][a-z0-9_]{0,63}$")
    private val PROP_KEY = Regex("^[A-Za-z0-9_]{1,40}$")
    private val CURRENCY = Regex("^[A-Z]{3}$")
    private val E164 = Regex("^\\+[1-9]\\d{7,14}$")

    /** The event to queue, or `null` (with a debug log) when it must be dropped. */
    fun event(
        name: String,
        props: Map<String, Any?>?,
        revenue: Revenue?,
        eventId: String,
        ts: Long,
        logger: Logger,
    ): QueueItem.Event? {
        fun drop(reason: String): QueueItem.Event? {
            logger.warn("event \"${name.take(80)}\" dropped: $reason")
            return null
        }
        if (!NAME.matches(name)) return drop("name must be snake_case, e.g. add_to_cart")

        val cleanRevenue = revenue?.let { r ->
            if (!r.amount.isFinite() || r.amount < 0) {
                return drop("revenue.amount must be a number of 0 or more (refunds come from your server)")
            }
            val currency = r.currency.trim().uppercase(Locale.ROOT)
            if (!CURRENCY.matches(currency)) return drop("revenue.currency must be an ISO 4217 code such as INR")
            val orderId = r.orderId?.takeIf { it.isNotEmpty() }
            if (orderId != null && orderId.length > MAX_ORDER_ID) {
                return drop("revenue.orderId is longer than $MAX_ORDER_ID characters")
            }
            Revenue(roundToCents(r.amount), currency, orderId)
        }

        return QueueItem.Event(
            eventId = eventId,
            name = name,
            ts = ts,
            props = props?.let { cleanProps(name, it, logger) }?.takeIf { it.isNotEmpty() },
            revenue = cleanRevenue,
        )
    }

    /** The identify to queue, or `null` (with a debug log) when the user id is unusable. */
    fun identify(userId: String, email: String?, phone: String?, logger: Logger): QueueItem.Identify? {
        val id = userId.trim()
        if (id.isEmpty() || id.length > MAX_USER_ID) {
            logger.warn("identify dropped: userId must be 1-$MAX_USER_ID characters")
            return null
        }
        if (Pii.isPersonal(id)) {
            logger.warn("identify dropped: userId looks like an email or phone number; pass your own opaque id")
            return null
        }

        val emailHash = email?.let {
            val normalized = it.trim().lowercase(Locale.ROOT)
            if (normalized.contains('@')) {
                Signer.sha256Hex(normalized.toByteArray(Charsets.UTF_8))
            } else {
                logger.warn("identify: email dropped: not an email address")
                null
            }
        }
        val phoneHash = phone?.let {
            val normalized = Pii.compactPhone(it)
            if (E164.matches(normalized)) {
                Signer.sha256Hex(normalized.toByteArray(Charsets.UTF_8))
            } else {
                logger.warn("identify: phone dropped: must be E.164, e.g. +919876543210")
                null
            }
        }
        return QueueItem.Identify(id, emailHash, phoneHash)
    }

    private fun cleanProps(event: String, props: Map<String, Any?>, logger: Logger): Map<String, Any?> {
        val clean = LinkedHashMap<String, Any?>()
        for ((key, raw) in props) {
            if (!PROP_KEY.matches(key)) {
                logger.warn("event $event: prop \"${key.take(40)}\" dropped: keys must match [A-Za-z0-9_]{1,40}")
                continue
            }
            val value = propValue(raw)
            if (value === INVALID) {
                logger.warn("event $event: prop $key dropped: values must be a string, finite number, boolean or null")
                continue
            }
            if (raw is String && Pii.isPersonal(raw)) {
                logger.warn("event $event: prop $key dropped: looks like an email or phone number")
                continue
            }
            if (clean.size == MAX_PROPS) {
                logger.warn("event $event: prop $key dropped: at most $MAX_PROPS props")
                continue
            }
            clean[key] = value
        }
        return clean
    }

    private val INVALID = Any()

    private fun propValue(value: Any?): Any? = when (value) {
        null, is Boolean -> value
        is String -> truncate(value)
        is Int, is Long, is Short, is Byte -> (value as Number).toLong()
        // Float via its decimal string, so 1.1f is sent as 1.1 rather than 1.100000023841858.
        is Float -> if (value.isFinite()) value.toString().toDouble() else INVALID
        is Number -> value.toDouble().takeIf { it.isFinite() } ?: INVALID
        else -> INVALID
    }

    /** Truncates to 256 UTF-16 units (what the server counts) without splitting a surrogate pair. */
    private fun truncate(value: String): String {
        if (value.length <= MAX_STRING) return value
        val end = if (Character.isHighSurrogate(value[MAX_STRING - 1])) MAX_STRING - 1 else MAX_STRING
        return value.substring(0, end)
    }

    /** Half-up to 2 decimals, on the decimal form of the number (so 1.005 becomes 1.01, not 1.00). */
    fun roundToCents(amount: Double): Double {
        val decimal = BigDecimal(amount.toString())
        return if (decimal.scale() <= 2) amount else decimal.setScale(2, RoundingMode.HALF_UP).toDouble()
    }
}
