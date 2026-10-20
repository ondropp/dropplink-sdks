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
            )
        } catch (e: Exception) {
            State()
        }
    }

    @Throws(IOException::class)
    fun write(state: State) {
        val json = JSONObject()
        state.installId?.let { json.put("installId", it) }
        json.put("attributed", state.attributed)
        state.attribution?.let { json.put("attribution", it.toJson()) }

        // Write to a temp file and rename over the old one, so a crash mid-write never leaves a half file.
        file.parentFile?.mkdirs()
        val tmp = File(file.parentFile, "${file.name}.tmp")
        tmp.writeText(json.toString(), Charsets.UTF_8)
        if (!tmp.renameTo(file)) {
            file.delete()
            if (!tmp.renameTo(file)) throw IOException("Could not write ${file.name}")
        }
    }
}
