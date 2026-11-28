package app.ondropp.dropplink.internal

import app.ondropp.dropplink.Dropplink
import org.json.JSONObject
import java.net.URLDecoder

internal data class Screen(val w: Int, val h: Int, val dpr: Double)

internal data class DeviceInfo(
    val model: String,
    val osVersion: String,
    val locale: String,
    val timezone: String,
    val screen: Screen?,
)

/** What the Play Install Referrer API returned. Timestamps are unix seconds; `null` when Play reports 0. */
internal data class InstallReferrer(
    val raw: String,
    val clickId: String?,
    val referrerClickTs: Long?,
    val installBeginTs: Long?,
) {
    companion object {
        fun fromRaw(raw: String, referrerClickTs: Long, installBeginTs: Long) = InstallReferrer(
            raw = raw,
            clickId = parseClickId(raw),
            referrerClickTs = referrerClickTs.takeIf { it > 0 },
            installBeginTs = installBeginTs.takeIf { it > 0 },
        )

        /** Reads `click_id` from a referrer string like `utm_source=dropp&click_id=c_8b1f…`. */
        fun parseClickId(raw: String): String? {
            for (pair in raw.split('&')) {
                val eq = pair.indexOf('=')
                if (eq <= 0) continue
                if (decode(pair.substring(0, eq)) == "click_id") {
                    return decode(pair.substring(eq + 1)).takeIf { it.isNotEmpty() }
                }
            }
            return null
        }

        private fun decode(s: String): String = try {
            URLDecoder.decode(s, "UTF-8")
        } catch (e: IllegalArgumentException) {
            s // Malformed %-escape: keep it as-is rather than drop the referrer.
        }
    }
}

/** `0.2.1` for native apps, `0.2.1-flutter` / `0.2.1-rn` for the wrappers (spec section 1). */
internal fun sdkVersionFor(platformWrapper: String?): String =
    if (platformWrapper.isNullOrBlank()) Dropplink.VERSION else "${Dropplink.VERSION}-$platformWrapper"

/** Builds the `/v1/init` body (spec section 4), truncated to the contract's limits. */
internal object InitBody {

    fun build(
        installId: String,
        appVersion: String,
        sdkVersion: String,
        device: DeviceInfo,
        installReferrer: InstallReferrer?,
    ): JSONObject {
        val body = JSONObject()
        body.put("installId", installId)
        body.put("platform", "android")
        body.put("appVersion", appVersion.ifBlank { "unknown" }.take(64))
        body.put("sdkVersion", sdkVersion.take(32))

        val deviceJson = JSONObject()
        deviceJson.put("model", device.model.take(100))
        deviceJson.put("osVersion", device.osVersion.take(32))
        deviceJson.put("locale", device.locale.take(35))
        deviceJson.put("timezone", device.timezone.take(64))
        device.screen?.takeIf { it.isValid() }?.let { screen ->
            deviceJson.put(
                "screen",
                JSONObject().put("w", screen.w).put("h", screen.h).put("dpr", screen.dpr),
            )
        }
        body.put("device", deviceJson)

        installReferrer?.let { referrer ->
            val json = JSONObject()
            json.put("raw", referrer.raw.take(2048))
            // A truncated click id would point at the wrong click, so an over-long one is dropped
            // (the server can still read `click_id` out of `raw`).
            referrer.clickId?.takeIf { it.length <= 64 }?.let { json.put("clickId", it) }
            referrer.referrerClickTs?.let { json.put("referrerClickTs", it) }
            referrer.installBeginTs?.let { json.put("installBeginTs", it) }
            body.put("installReferrer", json)
        }
        return body
    }

    private fun Screen.isValid() = w in 1..20_000 && h in 1..20_000 && dpr > 0 && dpr <= 10
}
