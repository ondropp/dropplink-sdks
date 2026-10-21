package app.ondropp.dropplink.internal

import app.ondropp.dropplink.Revenue
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * Spec section 10.6: events and identify bodies match contract/events/request.json and
 * contract/identify/request*.json; contract/events/response.partial.json parses.
 */
class EventBodyTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private val installId = "6f1c2a9e-3b7d-4c51-9a8e-2d4f6b1c0e73"
    private val logger = Logger(enabled = false)

    @Test
    fun eventsBodyMatchesTheRequestFixture() {
        val queue = EventQueue(tmp.root.resolve("q.json"), logger) { 1_760_700_300 }
        queue.add(
            EventValidation.event(
                name = "add_to_cart",
                props = mapOf("sku" to "TSHIRT-M", "qty" to 1),
                revenue = null,
                eventId = "3f2b8c1d-5e6a-4b7c-9d8e-0f1a2b3c4d5e",
                ts = 1760700100,
                logger = logger,
            )!!,
        )
        queue.add(
            EventValidation.event(
                name = "purchase",
                props = null,
                revenue = Revenue(499.0, "INR", "A1023"),
                eventId = "7a6b5c4d-3e2f-4a1b-8c9d-0e1f2a3b4c5d",
                ts = 1760700200,
                logger = logger,
            )!!,
        )

        val batch = queue.nextBatch(installId)!!
        assertEquals("/v1/events", batch.path)
        // Round-trip through bytes: that's what is actually signed and sent.
        val actual = JSONObject(batch.body.toString(Charsets.UTF_8))
        assertSameJson("", Contract.json("events/request.json"), actual)
        // A whole amount is sent as an integer, like the fixture's 499.
        val amount = actual.getJSONArray("events").getJSONObject(1).getJSONObject("revenue").get("amount")
        assertTrue("amount is $amount (${amount.javaClass})", amount is Int || amount is Long)
    }

    @Test
    fun identifyBodyMatchesTheRequestFixture() {
        // The email is trimmed and lower-cased before hashing.
        val identify = EventValidation.identify(" user_8812 ", "  Priya@Example.com ", null, logger)!!
        assertSameJson("", Contract.json("identify/request.json"), JSONObject(identify.toWire(installId).toString()))
    }

    @Test
    fun logoutBodyMatchesTheRequestFixture() {
        val body = JSONObject(QueueItem.Identify(userId = null).toWire(installId).toString())
        assertSameJson("", Contract.json("identify/request.logout.json"), body)
        assertEquals(JSONObject.NULL, body.get("userId"))
    }

    @Test
    fun identifyIsSentAloneToItsOwnEndpoint() {
        val queue = EventQueue(tmp.root.resolve("q.json"), logger) { 1_760_700_300 }
        queue.add(QueueItem.Identify("user_8812"))
        val batch = queue.nextBatch(installId)!!
        assertEquals("/v1/identify", batch.path)
        assertEquals(1, batch.items.size)
    }

    @Test
    fun parsesThePartialEventsResponse() {
        val response = Responses.parseEvents(Contract.text("events/response.partial.json"))
        assertEquals(1, response.accepted)
        assertEquals(0, response.duplicates)
        assertEquals(
            listOf(RejectedEvent(1, "7a6b5c4d-3e2f-4a1b-8c9d-0e1f2a3b4c5d", "too_old", "ts is more than 7 days ago")),
            response.rejected,
        )
        assertEquals(
            listOf(EventWarning("3f2b8c1d-5e6a-4b7c-9d8e-0f1a2b3c4d5e", "pii_in_props", listOf("email"))),
            response.warnings,
        )
    }

    @Test
    fun eventsResponseIgnoresUnknownFields() {
        val response = Responses.parseEvents("""{"accepted":2,"duplicates":1,"rejected":[],"warnings":[],"newField":true}""")
        assertEquals(2, response.accepted)
        assertEquals(1, response.duplicates)
    }
}
