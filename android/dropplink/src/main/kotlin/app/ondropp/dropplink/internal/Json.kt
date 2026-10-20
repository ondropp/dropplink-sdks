package app.ondropp.dropplink.internal

import app.ondropp.dropplink.Attribution
import org.json.JSONObject

// Small helpers over org.json (built into Android). `optString` turns JSON null into the string "null",
// so every optional read goes through `isNull` first.

internal fun JSONObject.stringOrNull(key: String): String? = if (isNull(key)) null else optString(key)

internal fun JSONObject.doubleOrNull(key: String): Double? =
    if (isNull(key)) null else optDouble(key).takeUnless { it.isNaN() }

internal fun JSONObject.toStringMap(): Map<String, String> {
    val map = LinkedHashMap<String, String>()
    for (key in keys()) {
        stringOrNull(key)?.let { map[key] = it }
    }
    return map
}

internal fun Attribution.toJson(): JSONObject = JSONObject().apply {
    put("type", type)
    put("method", method)
    clickId?.let { put("clickId", it) }
    linkId?.let { put("linkId", it) }
    campaignId?.let { put("campaignId", it) }
    creatorId?.let { put("creatorId", it) }
    source?.let { put("source", it) }
    confidence?.let { put("confidence", it) }
    attributedAt?.let { put("attributedAt", it) }
}
