package app.ondropp.dropplink.internal

import app.ondropp.dropplink.Revenue
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Spec section 10.8 and the `track` / `identify` rules of section 11. */
class EventValidationTest {

    private val logs = mutableListOf<String>()
    private val logger = Logger(enabled = true) { _, message -> logs += message }

    private fun event(name: String = "add_to_cart", props: Map<String, Any?>? = null, revenue: Revenue? = null) =
        EventValidation.event(name, props, revenue, "3f2b8c1d-5e6a-4b7c-9d8e-0f1a2b3c4d5e", 1760700100, logger)

    // --- contract/events/invalid ---------------------------------------------------------------------

    @Test
    fun handlesEveryInvalidContractEvent() {
        val files = Contract.list("events/invalid")
        assertTrue("no invalid fixtures found", files.isNotEmpty())
        for (file in files) {
            val json = Contract.json("events/invalid/$file")
            val result = EventValidation.event(
                name = json.getString("name"),
                props = json.optJSONObject("props")?.let { p -> p.keys().asSequence().associateWith { p.get(it) } },
                revenue = json.optJSONObject("revenue")?.let {
                    Revenue(it.getDouble("amount"), it.getString("currency"), it.stringOrNull("orderId"))
                },
                eventId = json.getString("eventId"),
                ts = json.getDouble("ts").toLong(),
                logger = logger,
            )
            when (file) {
                // The SDK creates eventId (a UUID) and ts (whole seconds) itself, so these can't happen.
                "event-id-not-uuid.json", "ts-not-integer.json" -> Unit
                "name-not-snake-case.json", "negative-revenue.json" -> assertNull(file, result)
                // Section 11 fixes these instead of dropping them.
                "currency-lower-case.json" -> assertEquals(file, "INR", result!!.revenue!!.currency)
                "three-decimals.json" -> assertEquals(file, 1.01, result!!.revenue!!.amount, 0.0)
                else -> fail("No expectation for new fixture $file: add one")
            }
        }
        assertTrue(logs.contains("event \"Add To Cart\" dropped: name must be snake_case, e.g. add_to_cart"))
    }

    // --- Event rules ---------------------------------------------------------------------------------

    @Test
    fun namesMustBeSnakeCase() {
        assertNotNull(event("a"))
        assertNotNull(event("purchase_2"))
        assertNotNull(event("a" + "b".repeat(63)))
        assertNull(event("a" + "b".repeat(64)))
        assertNull(event("2fast"))
        assertNull(event("_x"))
        assertNull(event("addToCart"))
        assertNull(event(""))
    }

    @Test
    fun dropsBadPropKeysAndKeepsTheFirstTwentyValidOnes() {
        val props = LinkedHashMap<String, Any?>()
        props["bad key"] = 1
        props["k".repeat(41)] = 1
        for (i in 1..25) props["p$i"] = i
        val kept = event(props = props)!!.props!!
        assertEquals((1..20).map { "p$it" }, kept.keys.toList())
    }

    @Test
    fun keepsAllowedValueTypesAndTruncatesLongStrings() {
        val kept = event(
            props = mapOf(
                "s" to "x".repeat(300),
                "i" to 3,
                "d" to 2.5,
                "f" to 1.1f,
                "b" to true,
                "n" to null,
                "nan" to Double.NaN,
                "inf" to Double.POSITIVE_INFINITY,
                "list" to listOf(1),
                "map" to mapOf("a" to 1),
            ),
        )!!.props!!
        assertEquals(listOf("s", "i", "d", "f", "b", "n"), kept.keys.toList())
        assertEquals(256, (kept["s"] as String).length)
        assertEquals(3L, kept["i"])
        assertEquals(1.1, kept["f"])
        assertNull(kept["n"])
    }

    @Test
    fun dropsPropsThatLookLikeAnEmailOrPhone() {
        val kept = event(
            props = mapOf(
                "email" to "contact me at priya@example.com",
                "phone" to "+91 98765 43210",
                "mobile" to "98765-43210",
                "orderId" to "A1023",
                "count" to 9876543210L, // Numbers aren't checked, like the server.
            ),
        )!!.props!!
        assertEquals(listOf("orderId", "count"), kept.keys.toList())
        assertFalse("values must never be logged", logs.any { it.contains("priya@example.com") || it.contains("98765") })
    }

    @Test
    fun propsThatAreAllDroppedAreOmitted() {
        assertNull(event(props = mapOf("bad key" to 1))!!.props)
        assertFalse(event(props = emptyMap())!!.toWire().has("props"))
    }

    @Test
    fun revenueRules() {
        assertNull(event(revenue = Revenue(-0.01, "INR")))
        assertNull(event(revenue = Revenue(Double.NaN, "INR")))
        assertNull(event(revenue = Revenue(Double.POSITIVE_INFINITY, "INR")))
        assertNull(event(revenue = Revenue(1.0, "RUPEES")))
        assertNull(event(revenue = Revenue(1.0, "IN")))
        assertNull(event(revenue = Revenue(1.0, "INR", "o".repeat(129))))

        assertEquals(Revenue(0.0, "USD", null), event(revenue = Revenue(0.0, " usd "))!!.revenue)
        assertEquals(Revenue(1.0, "INR", null), event(revenue = Revenue(1.0, "INR", ""))!!.revenue)
        assertEquals("o".repeat(128), event(revenue = Revenue(1.0, "INR", "o".repeat(128)))!!.revenue!!.orderId)
        assertEquals(2.68, event(revenue = Revenue(2.675, "INR"))!!.revenue!!.amount, 0.0)
        assertEquals(19.99, event(revenue = Revenue(19.99, "INR"))!!.revenue!!.amount, 0.0)
    }

    // --- identify ------------------------------------------------------------------------------------

    @Test
    fun userIdIsTrimmedAndMustBeOpaque() {
        assertEquals("user_8812", EventValidation.identify("  user_8812\n", null, null, logger)!!.userId)
        assertNull(EventValidation.identify("   ", null, null, logger))
        assertNull(EventValidation.identify("u".repeat(129), null, null, logger))
        assertNotNull(EventValidation.identify("u".repeat(128), null, null, logger))
        assertNull(EventValidation.identify("priya@example.com", null, null, logger))
        assertNull(EventValidation.identify("+919876543210", null, null, logger))
        assertNull(EventValidation.identify("9876543210", null, null, logger))
    }

    @Test
    fun traitsAreHashedAndBadOnesDropped() {
        val identify = EventValidation.identify("user_1", "PRIYA@example.com", "+91 (98765) 43-210", logger)!!
        assertEquals(Signer.sha256Hex("priya@example.com".toByteArray()), identify.emailHash)
        assertEquals(Signer.sha256Hex("+919876543210".toByteArray()), identify.phoneHash)

        val bad = EventValidation.identify("user_1", "not-an-email", "98765 43210", logger)!!
        assertNull(bad.emailHash)
        assertNull(bad.phoneHash)
        assertFalse(JSONObject(bad.toWire("x").toString()).has("traits"))
        assertNull(EventValidation.identify("user_1", null, "+0123456789", logger)!!.phoneHash)
        assertFalse("plain traits must never be logged", logs.any { it.contains("PRIYA") || it.contains("(98765)") || it.contains("98765 43210") })
    }

    // --- The server's pii.ts -------------------------------------------------------------------------

    @Test
    fun piiRulesMatchTheServer() {
        assertTrue(Pii.looksLikeEmail("a@b.co"))
        assertTrue(Pii.looksLikeEmail("mail me: x.y+z@mail.example.org!"))
        assertFalse(Pii.looksLikeEmail("a@b.c"))
        assertFalse(Pii.looksLikeEmail("@handle"))
        assertFalse(Pii.looksLikeEmail("a @b.co"))

        assertTrue(Pii.looksLikePhone("+919876543210"))
        assertTrue(Pii.looksLikePhone("+1 (415) 555-0100"))
        assertTrue(Pii.looksLikePhone("9876543210"))
        assertTrue(Pii.looksLikePhone("09876543210"))
        assertTrue(Pii.looksLikePhone("919876543210"))
        assertTrue(Pii.looksLikePhone("98765.43210"))
        assertTrue(Pii.looksLikePhone("98765 43210")) // JavaScript's \s includes no-break space.
        assertFalse(Pii.looksLikePhone("5876543210")) // Indian mobiles start 6–9.
        assertFalse(Pii.looksLikePhone("+123456789")) // Too short.
        assertFalse(Pii.looksLikePhone("1760700100"))
        assertFalse(Pii.looksLikePhone("A1023"))
        assertFalse(Pii.looksLikePhone("call 9876543210")) // Must be the whole value.
    }
}
