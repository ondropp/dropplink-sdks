package app.ondropp.dropplink.internal

import app.ondropp.dropplink.Attribution
import org.json.JSONException
import org.json.JSONObject

/** The `deepLink` object of `/v1/init` and `/v1/deeplink` responses. */
internal data class DeepLinkTarget(val path: String, val params: Map<String, String>)

internal class InitResponse(val attribution: Attribution, val deepLink: DeepLinkTarget?)

/** [redirectUrl]: the link has a custom redirect, so the open belongs in the browser, not the app. */
internal class DeepLinkResponse(val clickId: String?, val deepLink: DeepLinkTarget?, val redirectUrl: String?)

/** `/v1/events` 200: every event of the batch is accepted, a duplicate of an earlier attempt, or rejected. */
internal class EventsResponse(
    val accepted: Int,
    val duplicates: Int,
    val rejected: List<RejectedEvent>,
    val warnings: List<EventWarning>,
)

internal data class RejectedEvent(val index: Int, val eventId: String?, val code: String, val message: String)

/** E.g. `pii_in_props`: the server dropped [props] from the event before storing it. */
internal data class EventWarning(val eventId: String?, val code: String, val props: List<String>)

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
        return DeepLinkResponse(
            clickId = json.stringOrNull("clickId"),
            deepLink = parseDeepLinkTarget(json),
            redirectUrl = json.stringOrNull("redirectUrl"),
        )
    }

    @Throws(JSONException::class)
    fun parseEvents(body: String): EventsResponse {
        val json = JSONObject(body)
        val rejected = json.optJSONArray("rejected")
        val warnings = json.optJSONArray("warnings")
        return EventsResponse(
            accepted = json.optInt("accepted"),
            duplicates = json.optInt("duplicates"),
            rejected = (0 until (rejected?.length() ?: 0)).map { i ->
                val item = rejected!!.getJSONObject(i)
                RejectedEvent(item.optInt("index", -1), item.stringOrNull("eventId"), item.optString("code"), item.optString("message"))
            },
            warnings = (0 until (warnings?.length() ?: 0)).map { i ->
                val item = warnings!!.getJSONObject(i)
                val props = item.optJSONArray("props")
                EventWarning(
                    eventId = item.stringOrNull("eventId"),
                    code = item.optString("code"),
                    props = (0 until (props?.length() ?: 0)).map { props!!.getString(it) },
                )
            },
        )
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
