package app.ondropp.dropplink.internal

import app.ondropp.dropplink.Revenue
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException

/** One entry of the on-disk queue (spec section 11). */
internal sealed class QueueItem {
    /** The entry as stored in the queue file. */
    abstract fun toJson(): JSONObject

    /** Size in the file; also an upper bound of its size in a request body. */
    val bytes: Int by lazy { toJson().toString().toByteArray(Charsets.UTF_8).size }

    /** `eventId` and `ts` are fixed when `track` is called, so every retry sends the same values. */
    data class Event(
        val eventId: String,
        val name: String,
        val ts: Long,
        val props: Map<String, Any?>?,
        val revenue: Revenue?,
    ) : QueueItem() {

        fun toWire(): JSONObject = JSONObject().apply {
            put("eventId", eventId)
            put("name", name)
            put("ts", ts)
            props?.let { map ->
                val json = JSONObject()
                map.forEach { (key, value) -> json.put(key, value ?: JSONObject.NULL) }
                put("props", json)
            }
            revenue?.let { r ->
                val json = JSONObject()
                // Whole amounts go out as integers (499, not 499.0), the same on every platform.
                json.put("amount", if (r.amount == Math.rint(r.amount) && r.amount < 1e15) r.amount.toLong() else r.amount)
                json.put("currency", r.currency)
                r.orderId?.let { json.put("orderId", it) }
                put("revenue", json)
            }
        }

        override fun toJson(): JSONObject = toWire().put("kind", KIND_EVENT)
    }

    /** `userId == null` is a logout. Traits are SHA-256 hashes; the plain values are never stored. */
    data class Identify(val userId: String?, val emailHash: String? = null, val phoneHash: String? = null) : QueueItem() {

        fun toWire(installId: String): JSONObject = JSONObject().apply {
            put("installId", installId)
            put("userId", userId ?: JSONObject.NULL)
            if (emailHash != null || phoneHash != null) {
                val traits = JSONObject()
                emailHash?.let { traits.put("emailHash", it) }
                phoneHash?.let { traits.put("phoneHash", it) }
                put("traits", traits)
            }
        }

        override fun toJson(): JSONObject = JSONObject().apply {
            put("kind", KIND_IDENTIFY)
            put("userId", userId ?: JSONObject.NULL)
            emailHash?.let { put("emailHash", it) }
            phoneHash?.let { put("phoneHash", it) }
        }
    }

    companion object {
        const val KIND_EVENT = "event"
        const val KIND_IDENTIFY = "identify"

        fun fromJson(json: JSONObject): QueueItem? = when (json.optString("kind")) {
            KIND_EVENT -> Event(
                eventId = json.getString("eventId"),
                name = json.getString("name"),
                ts = json.getLong("ts"),
                props = json.optJSONObject("props")?.let(::propsFromJson),
                revenue = json.optJSONObject("revenue")?.let {
                    Revenue(it.getDouble("amount"), it.getString("currency"), it.stringOrNull("orderId"))
                },
            )
            KIND_IDENTIFY -> Identify(json.stringOrNull("userId"), json.stringOrNull("emailHash"), json.stringOrNull("phoneHash"))
            else -> null
        }

        private fun propsFromJson(json: JSONObject): Map<String, Any?> {
            val map = LinkedHashMap<String, Any?>()
            for (key in json.keys()) {
                map[key] = when (val value = json.get(key)) {
                    JSONObject.NULL -> null
                    is Int -> value.toLong()
                    is String, is Boolean, is Long, is Double -> value
                    is Number -> value.toDouble()
                    else -> continue
                }
            }
            return map
        }
    }
}

/** What one request of a flush sends: [items] leave the queue once the server has answered for them. */
internal class Batch(val path: String, val items: List<QueueItem>, val body: ByteArray)

/**
 * The event queue (spec section 11): `track`, `identify` and `logout` entries in order, persisted as
 * `dropplink-queue.json` next to `dropplink.json`.
 *
 * Thread-safe. The file is rewritten (temp file, then rename) on every change, so a kill mid-write never
 * corrupts it. It is loaded on first use; events more than 7 days old are dropped on load and by [prune].
 */
internal class EventQueue(
    private val file: File,
    private val logger: Logger,
    private val nowSec: () -> Long,
) {
    private val lock = Any()
    private var loaded = false
    private val items = ArrayList<QueueItem>()
    private var lastUserId: String? = null
    private var eventCount = 0
    private var bytes = FILE_OVERHEAD

    val size: Int get() = synchronized(lock) { load(); items.size }

    fun items(): List<QueueItem> = synchronized(lock) { load(); items.toList() }

    /** The user id of the last identify queued or sent; `null` after logout or when unknown. */
    fun lastUserId(): String? = synchronized(lock) { load(); lastUserId }

    /** Appends [event], dropping older events first when the caps would be exceeded. Returns the queue size. */
    fun add(event: QueueItem.Event): Int = synchronized(lock) {
        load()
        while (eventCount >= MAX_EVENTS || bytes + event.bytes + 1 > MAX_BYTES) {
            // Oldest non-revenue event first; revenue is only given up for newer revenue.
            val victim = items.firstOrNull { it is QueueItem.Event && it.revenue == null }
                ?: if (event.revenue == null) {
                    logger.warn("event ${event.name} dropped: the queue is full of revenue events")
                    return items.size
                } else {
                    items.firstOrNull { it is QueueItem.Event }
                }
                ?: break // Only identifies left; they are never dropped.
            logger.warn("queue full: dropped the oldest event ${(victim as QueueItem.Event).name}")
            removeLocked(victim)
        }
        addLocked(event)
        persist()
        items.size
    }

    /** Appends an identify (or a logout, `userId == null`) and remembers its user id. */
    fun add(identify: QueueItem.Identify): Int = synchronized(lock) {
        load()
        addLocked(identify)
        lastUserId = identify.userId
        persist()
        items.size
    }

    /** Empties the queue and forgets the last user id (`setTrackingEnabled(false)`). */
    fun clear(): Unit = synchronized(lock) {
        loaded = true
        items.clear()
        lastUserId = null
        eventCount = 0
        bytes = FILE_OVERHEAD
        persist()
    }

    /** Drops events whose `ts` is more than 7 days old: the server would reject them. */
    fun prune(): Unit = synchronized(lock) {
        load()
        if (pruneLocked() > 0) persist()
    }

    /**
     * The next request of a flush: an identify alone, or up to 100 consecutive events (stopping before the
     * next identify) whose body stays within 60 KB. `null` when the queue is empty.
     */
    fun nextBatch(installId: String): Batch? = synchronized(lock) {
        load()
        val head = items.firstOrNull() ?: return null
        if (head is QueueItem.Identify) {
            return Batch("/v1/identify", listOf(head), head.toWire(installId).toString().toByteArray(Charsets.UTF_8))
        }
        val events = ArrayList<QueueItem.Event>()
        var size = BODY_OVERHEAD + installId.length
        for (item in items) {
            if (item !is QueueItem.Event || events.size == MAX_BATCH_EVENTS) break
            val added = item.bytes + 1
            if (events.isNotEmpty() && size + added > MAX_BODY_BYTES) break
            events += item
            size += added
        }
        val body = JSONObject()
            .put("installId", installId)
            .put("events", JSONArray().apply { events.forEach { put(it.toWire()) } })
        Batch("/v1/events", events, body.toString().toByteArray(Charsets.UTF_8))
    }

    /** Removes [sent] (by identity, so entries cleared or dropped meanwhile are simply skipped). */
    fun remove(sent: List<QueueItem>): Unit = synchronized(lock) {
        load()
        var changed = false
        for (item in sent) {
            val index = items.indexOfFirst { it === item }
            if (index >= 0) {
                removeLocked(items[index])
                changed = true
            }
        }
        if (changed) persist()
    }

    private fun addLocked(item: QueueItem) {
        items += item
        bytes += item.bytes + 1
        if (item is QueueItem.Event) eventCount++
    }

    private fun removeLocked(item: QueueItem) {
        val index = items.indexOfFirst { it === item }
        if (index < 0) return
        items.removeAt(index)
        bytes -= item.bytes + 1
        if (item is QueueItem.Event) eventCount--
    }

    private fun pruneLocked(): Int {
        val oldest = nowSec() - MAX_AGE_SEC
        val old = items.filter { it is QueueItem.Event && it.ts < oldest }
        old.forEach(::removeLocked)
        if (old.isNotEmpty()) logger.debug("dropped ${old.size} events older than 7 days")
        return old.size
    }

    private fun load() {
        if (loaded) return
        loaded = true
        if (!file.exists()) return
        try {
            val json = JSONObject(file.readText(Charsets.UTF_8))
            if (json.optInt("v") != VERSION) throw IllegalStateException("unknown version ${json.opt("v")}")
            lastUserId = json.stringOrNull("lastUserId")
            val array = json.getJSONArray("items")
            for (i in 0 until array.length()) {
                // One unreadable entry shouldn't cost the rest of the queue.
                val item = try {
                    QueueItem.fromJson(array.getJSONObject(i))
                } catch (e: Exception) {
                    null
                }
                item?.let(::addLocked)
            }
        } catch (e: Exception) {
            logger.debug("queue file unreadable, discarded: $e")
            items.clear()
            lastUserId = null
            eventCount = 0
            bytes = FILE_OVERHEAD
            file.delete()
            return
        }
        if (pruneLocked() > 0) persist()
    }

    private fun persist() {
        val json = JSONObject()
        json.put("v", VERSION)
        json.put("lastUserId", lastUserId ?: JSONObject.NULL)
        json.put("items", JSONArray().apply { items.forEach { put(it.toJson()) } })
        try {
            writeAtomically(file, json.toString())
        } catch (e: IOException) {
            logger.error("Could not save the event queue: $e")
        }
    }

    companion object {
        const val VERSION = 1
        const val MAX_EVENTS = 1_000
        const val MAX_BYTES = 1024 * 1024
        const val MAX_BATCH_EVENTS = 100
        const val MAX_BODY_BYTES = 60 * 1024
        const val MAX_AGE_SEC = 7 * 24 * 60 * 60L

        // `{"v":1,"lastUserId":"<128 chars>","items":[]}` and `{"installId":"","events":[]}`, rounded up.
        private const val FILE_OVERHEAD = 192
        private const val BODY_OVERHEAD = 32
    }
}

/** Writes to a temp file and renames it over [file], so a crash mid-write never leaves a half file. */
@Throws(IOException::class)
internal fun writeAtomically(file: File, text: String) {
    file.parentFile?.mkdirs()
    val tmp = File(file.parentFile, "${file.name}.tmp")
    tmp.writeText(text, Charsets.UTF_8)
    if (!tmp.renameTo(file)) {
        file.delete()
        if (!tmp.renameTo(file)) throw IOException("Could not write ${file.name}")
    }
}
