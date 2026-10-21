package app.ondropp.dropplink.internal

import app.ondropp.dropplink.Revenue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.util.UUID

/** Spec section 10.7: caps and drop order, batching, pruning and persistence of the queue file. */
class EventQueueTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private val installId = "6f1c2a9e-3b7d-4c51-9a8e-2d4f6b1c0e73"
    private val nowSec = 1_760_700_000L
    private val file by lazy { tmp.root.resolve("dropplink-queue.json") }
    private val logs = mutableListOf<String>()
    private val logger = Logger(enabled = true) { _, message -> logs += message }

    private fun queue() = EventQueue(file, logger) { nowSec }

    private fun event(name: String = "view", revenue: Revenue? = null, ts: Long = nowSec, props: Map<String, Any?>? = null) =
        QueueItem.Event(UUID.randomUUID().toString(), name, ts, props, revenue)

    private val QueueItem.name get() = (this as QueueItem.Event).name

    @Test
    fun persistsAcrossRestarts() {
        val first = queue()
        val purchase = event("purchase", Revenue(499.0, "INR", "A1023"), props = mapOf("sku" to "X", "qty" to 2L, "gift" to null))
        first.add(event("add_to_cart"))
        first.add(QueueItem.Identify("user_8812", emailHash = "ab".repeat(32)))
        first.add(purchase)

        val second = queue()
        assertEquals(3, second.size)
        assertEquals("user_8812", second.lastUserId())
        assertEquals(QueueItem.Identify("user_8812", emailHash = "ab".repeat(32)), second.items()[1])
        val restored = second.items()[2] as QueueItem.Event
        assertEquals(purchase.eventId, restored.eventId)
        assertEquals(purchase.ts, restored.ts)
        assertEquals(purchase.props, restored.props)
        assertEquals(purchase.revenue, restored.revenue)
        assertFalse(tmp.root.resolve("dropplink-queue.json.tmp").exists())
    }

    @Test
    fun corruptOrUnknownFilesAreDiscarded() {
        file.writeText("{not json")
        assertEquals(0, queue().size)
        assertTrue(logs.any { it.contains("queue file unreadable") })

        file.writeText("""{"v":99,"lastUserId":"u","items":[]}""")
        val q = queue()
        assertEquals(0, q.size)
        assertNull(q.lastUserId())
    }

    @Test
    fun dropsEventsOlderThanSevenDaysOnLoad() {
        val first = queue()
        first.add(event("old", ts = nowSec - 7 * 86_400 - 1))
        first.add(event("recent", ts = nowSec - 7 * 86_400))
        first.add(QueueItem.Identify(null))
        assertEquals(listOf("recent"), queue().items().filterIsInstance<QueueItem.Event>().map { it.name })
        assertEquals(2, queue().size)
    }

    @Test
    fun atMostAThousandEventsDroppingTheOldestNonRevenueFirst() {
        val q = queue()
        q.add(event("paid_0", Revenue(1.0, "INR")))
        q.add(QueueItem.Identify("u"))
        for (i in 1..999) q.add(event("view_$i"))
        q.add(event("view_1000"))

        val names = q.items().filterIsInstance<QueueItem.Event>().map { it.name }
        assertEquals(1000, names.size)
        assertEquals("paid_0", names.first())
        assertFalse(names.contains("view_1"))
        assertEquals("view_1000", names.last())
        assertTrue(q.items().any { it is QueueItem.Identify })
    }

    @Test
    fun whenOnlyRevenueIsLeftNewNonRevenueEventsAreDropped() {
        val q = queue()
        for (i in 0 until 1000) q.add(event("paid_$i", Revenue(1.0, "INR")))
        q.add(event("view"))
        assertEquals("paid_0", q.items().first().name)
        assertFalse(q.items().any { it.name == "view" })

        q.add(event("paid_new", Revenue(2.0, "INR")))
        assertEquals(1000, q.size)
        assertEquals("paid_1", q.items().first().name)
        assertEquals("paid_new", q.items().last().name)
    }

    @Test
    fun theFileStaysUnderOneMegabyte() {
        val q = queue()
        val big = (1..20).associate { "p$it" to "x".repeat(256) }
        q.add(QueueItem.Identify("u"))
        repeat(250) { q.add(event("big_$it", props = big)) }

        assertTrue("file is ${file.length()} bytes", file.length() <= EventQueue.MAX_BYTES)
        assertTrue(q.size < 251)
        assertEquals("big_249", q.items().last().name)
        assertTrue("identify entries are never dropped", q.items().first() is QueueItem.Identify)
    }

    @Test
    fun batchesStopAtAnIdentifyAndAtOneHundredEvents() {
        val q = queue()
        repeat(150) { q.add(event("e_$it")) }
        q.add(QueueItem.Identify("u"))
        q.add(event("after"))

        val first = q.nextBatch(installId)!!
        assertEquals(100, first.items.size)
        q.remove(first.items)
        val second = q.nextBatch(installId)!!
        assertEquals(50, second.items.size)
        q.remove(second.items)
        val identify = q.nextBatch(installId)!!
        assertEquals("/v1/identify", identify.path)
        q.remove(identify.items)
        assertEquals(listOf("after"), q.nextBatch(installId)!!.items.map { it.name })
    }

    @Test
    fun batchBodiesStayUnderSixtyKilobytes() {
        val q = queue()
        val big = (1..20).associate { "p$it" to "x".repeat(256) }
        repeat(30) { q.add(event("big_$it", props = big)) }

        val batch = q.nextBatch(installId)!!
        assertTrue("body is ${batch.body.size} bytes", batch.body.size <= EventQueue.MAX_BODY_BYTES)
        assertTrue(batch.items.size in 2 until 30)
    }

    @Test
    fun clearEmptiesTheQueueAndForgetsTheUser() {
        val q = queue()
        q.add(QueueItem.Identify("u"))
        q.add(event())
        q.clear()
        assertEquals(0, queue().size)
        assertNull(queue().lastUserId())
        assertNull(q.nextBatch(installId))
    }
}
