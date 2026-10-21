package app.ondropp.dropplink.internal

import app.ondropp.dropplink.Attribution
import org.json.JSONObject
import java.io.File
import java.io.IOException

/**
 * The SDK's persisted state (spec section 6) as one small JSON file.
 *
 * On Android the file lives in `Context.noBackupFilesDir`: Auto Backup would copy SharedPreferences to
 * a new phone, and two devices would then share one install id.
 */
internal class Storage(private val file: File) {

    data class State(
        val installId: String? = null,
        val attributed: Boolean = false,
        val attribution: Attribution? = null,
        /** `false` after `setTrackingEnabled(false)`; absent in the file means `true`. */
        val trackingEnabled: Boolean = true,
    )

    /** An unreadable or corrupt file reads as empty, which means a fresh install id. */
    fun read(): State {
        if (!file.exists()) return State()
        return try {
            val json = JSONObject(file.readText(Charsets.UTF_8))
            State(
                installId = json.stringOrNull("installId"),
                attributed = json.optBoolean("attributed", false),
                attribution = json.optJSONObject("attribution")?.let { Responses.parseAttribution(it) },
                trackingEnabled = json.optBoolean("trackingEnabled", true),
            )
        } catch (e: Exception) {
            State()
        }
    }

    // Synchronized: init (network thread) and setTrackingEnabled (I/O thread) both write.
    @Synchronized
    @Throws(IOException::class)
    fun write(state: State) {
        val json = JSONObject()
        state.installId?.let { json.put("installId", it) }
        json.put("attributed", state.attributed)
        state.attribution?.let { json.put("attribution", it.toJson()) }
        if (!state.trackingEnabled) json.put("trackingEnabled", false)
        writeAtomically(file, json.toString())
    }
}
