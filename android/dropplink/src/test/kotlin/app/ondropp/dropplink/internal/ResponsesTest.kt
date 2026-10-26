package app.ondropp.dropplink.internal

import app.ondropp.dropplink.Attribution
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Spec section 10.3: parse every response fixture. */
class ResponsesTest {

    @Test
    fun parsesAttributedInit() {
        val response = Responses.parseInit(Contract.text("init/response.attributed.json"))
        assertEquals(
            Attribution(
                type = "attributed",
                method = "install_referrer",
                clickId = "c_8b1f0e7d2a4c4f6e",
                linkId = "6711a0c2f1e4b8a9c3d2e1f0",
                campaignId = "6711a0c2f1e4b8a9c3d2e1f1",
                creatorId = "6711a0c2f1e4b8a9c3d2e1f2",
                source = "instagram",
                confidence = 1.0,
                attributedAt = "2026-10-17T10:00:42.000Z",
            ),
            response.attribution,
        )
        assertEquals(DeepLinkTarget("/product/123", mapOf("ref" to "creator", "variant" to "red")), response.deepLink)
    }

    @Test
    fun parsesOrganicInit() {
        val response = Responses.parseInit(Contract.text("init/response.organic.json"))
        assertEquals("organic", response.attribution.type)
        assertEquals("none", response.attribution.method)
        assertNull(response.attribution.clickId)
        assertNull(response.attribution.confidence)
        assertNull(response.deepLink)
    }

    @Test
    fun parsesMatchedDeepLink() {
        val response = Responses.parseDeepLink(Contract.text("deeplink/response.matched.json"))
        assertEquals("c_3d9a0b1c2e4f6a8b", response.clickId)
        assertEquals(DeepLinkTarget("/product/123", mapOf("variant" to "red", "ref" to "story")), response.deepLink)
        assertNull(response.redirectUrl)
    }

    @Test
    fun parsesCustomRedirectDeepLink() {
        val response = Responses.parseDeepLink(Contract.text("deeplink/response.redirect.json"))
        assertEquals("c_3d9a0b1c2e4f6a8b", response.clickId)
        assertNull(response.deepLink)
        assertEquals(
            "https://brand.com/blog?dropp_click_id=c_3d9a0b1c2e4f6a8b&utm_source=instagram&utm_medium=link&utm_campaign=blog",
            response.redirectUrl,
        )
    }

    @Test
    fun parsesUnmatchedDeepLink() {
        val response = Responses.parseDeepLink(Contract.text("deeplink/response.none.json"))
        assertNull(response.clickId)
        assertNull(response.deepLink)
    }

    @Test
    fun ignoresUnknownFields() {
        val response = Responses.parseInit(
            """{"installId":"x","attribution":{"type":"organic","method":"none","newField":1},"deepLink":null,"extra":{"a":1}}""",
        )
        assertEquals("organic", response.attribution.type)
    }

    @Test
    fun parsesErrorBodies() {
        assertEquals(ApiError("invalid_key", "nope", null), Responses.parseError(errorBody("invalid_key", "nope")))
        val withDetails = Responses.parseError(
            """{"error":{"code":"validation_failed","message":"bad","details":[{"path":"device","message":"Required"}]}}""",
        )
        assertEquals("validation_failed", withDetails?.code)
        assertEquals("""[{"path":"device","message":"Required"}]""", withDetails?.details)
        assertNull(Responses.parseError("<html>Bad gateway</html>"))
    }

    @Test
    fun attributionMapHasEveryField() {
        val attribution = Responses.parseInit(Contract.text("init/response.attributed.json")).attribution
        assertEquals(
            listOf("type", "method", "clickId", "linkId", "campaignId", "creatorId", "source", "confidence", "attributedAt"),
            attribution.toMap().keys.toList(),
        )
    }
}
