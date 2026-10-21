package app.ondropp.dropplink.internal

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Spec section 10.2: the init body has the fields and types of contract/init/request.android.json. */
class InitBodyTest {

    private val env = FakeEnvironment()

    private fun build(referrer: InstallReferrer? = env.referrer, device: DeviceInfo = env.deviceInfo()) =
        InitBody.build(
            installId = "6f1c2a9e-3b7d-4c51-9a8e-2d4f6b1c0e73",
            appVersion = "3.2.1",
            sdkVersion = "0.1.0",
            device = device,
            installReferrer = referrer,
        )

    @Test
    fun matchesTheAndroidRequestFixture() {
        val expected = Contract.json("init/request.android.json")
        // Round-trip through bytes: that's what is actually signed and sent.
        val actual = JSONObject(build().toString())
        assertSameJson("", expected, actual)
    }

    @Test
    fun screenSizesAreIntegers() {
        val screen = build().getJSONObject("device").getJSONObject("screen")
        assertTrue(screen.get("w") is Int)
        assertTrue(screen.get("h") is Int)
    }

    @Test
    fun omitsReferrerWhenNoneWasRead() {
        assertFalse(build(referrer = null).has("installReferrer"))
    }

    @Test
    fun truncatesToContractLimits() {
        val device = env.deviceInfo().copy(model = "m".repeat(150), timezone = "t".repeat(100), screen = null)
        val body = build(device = device).getJSONObject("device")
        assertEquals(100, body.getString("model").length)
        assertEquals(64, body.getString("timezone").length)
        assertFalse(body.has("screen"))
    }

    @Test
    fun sdkVersionCarriesTheWrapperSuffix() {
        assertEquals("0.2.0", sdkVersionFor(null))
        assertEquals("0.2.0-flutter", sdkVersionFor("flutter"))
        assertEquals("0.2.0-rn", sdkVersionFor("rn"))
    }

    @Test
    fun parsesClickIdFromRawReferrer() {
        assertEquals("c_8b1f", InstallReferrer.parseClickId("utm_source=dropp&click_id=c_8b1f"))
        assertEquals("c_8b1f", InstallReferrer.parseClickId("click_id=c_8b1f&utm_medium=x"))
        assertEquals("a b", InstallReferrer.parseClickId("click_id=a%20b"))
        assertNull(InstallReferrer.parseClickId("utm_source=google-play&utm_medium=organic"))
        assertNull(InstallReferrer.parseClickId(""))
    }

    @Test
    fun dropsZeroReferrerTimestamps() {
        val referrer = InstallReferrer.fromRaw("utm_source=google-play", 0, 0)
        val json = build(referrer = referrer).getJSONObject("installReferrer")
        assertEquals(setOf("raw"), json.keys().asSequence().toSet())
    }
}
