package app.ondropp.dropplink.internal

import app.ondropp.dropplink.Attribution
import org.json.JSONException
import org.json.JSONObject

/** The `deepLink` object of `/v1/init` and `/v1/deeplink` responses. */
internal data class DeepLinkTarget(val path: String, val params: Map<String, String>)

internal class InitResponse(val attribution: Attribution, val deepLink: DeepLinkTarget?)

internal class DeepLinkResponse(val clickId: String?, val deepLink: DeepLinkTarget?)

/** `{ "error": { "code", "message", "details"? } }` */
internal data class ApiError(val code: String, val message: String, val details: String?)

/**
 * Response parsing. Unknown fields are ignored (spec section 9.4) so the server can add fields
 * without breaking released SDKs.
 */
internal object Responses {

    @Throws(JSONException::class)
    fun parseInit(body: String): InitResponse {
        val json = JSONObject(body)
        return InitResponse(
            attribution = parseAttribution(json.getJSONObject("attribution")),
            deepLink = parseDeepLinkTarget(json),
        )
    }

    @Throws(JSONException::class)
    fun parseDeepLink(body: String): DeepLinkResponse {
        val json = JSONObject(body)
        return DeepLinkResponse(clickId = json.stringOrNull("clickId"), deepLink = parseDeepLinkTarget(json))
    }

    /** `null` when the body isn't the standard error shape (e.g. an HTML page from a proxy). */
    fun parseError(body: String): ApiError? = try {
        val error = JSONObject(body).getJSONObject("error")
        ApiError(
            code = error.getString("code"),
            message = error.optString("message"),
            details = if (error.isNull("details")) null else error.get("details").toString(),
        )
    } catch (e: JSONException) {
        null
    }

    @Throws(JSONException::class)
    fun parseAttribution(json: JSONObject): Attribution = Attribution(
        type = json.getString("type"),
        method = json.getString("method"),
        clickId = json.stringOrNull("clickId"),
        linkId = json.stringOrNull("linkId"),
        campaignId = json.stringOrNull("campaignId"),
        creatorId = json.stringOrNull("creatorId"),
        source = json.stringOrNull("source"),
        confidence = json.doubleOrNull("confidence"),
        attributedAt = json.stringOrNull("attributedAt"),
    )

    private fun parseDeepLinkTarget(parent: JSONObject): DeepLinkTarget? {
        val link = parent.optJSONObject("deepLink") ?: return null
        val path = link.stringOrNull("path") ?: return null
        val params = link.optJSONObject("params")?.toStringMap() ?: emptyMap()
        return DeepLinkTarget(path, params)
    }
}
