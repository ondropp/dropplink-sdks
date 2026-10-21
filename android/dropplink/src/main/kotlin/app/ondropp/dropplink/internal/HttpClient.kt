package app.ondropp.dropplink.internal

import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL

internal class HttpResponse(val status: Int, val body: String, headers: Map<String, String> = emptyMap()) {
    private val headers = headers.mapKeys { it.key.lowercase() }

    /** Header names are case-insensitive. */
    fun header(name: String): String? = headers[name.lowercase()]
}

/** The one network call the SDK makes. An interface so tests can swap in a fake. */
internal interface HttpClient {
    /** Returns any HTTP status as a response; throws [IOException] only for network failures. */
    @Throws(IOException::class)
    fun post(url: String, headers: Map<String, String>, body: ByteArray): HttpResponse
}

/** [HttpClient] on the platform's [HttpURLConnection], so the SDK needs no HTTP library. */
internal class UrlConnectionHttpClient(
    private val connectTimeoutMs: Int = 10_000,
    private val readTimeoutMs: Int = 10_000,
) : HttpClient {

    override fun post(url: String, headers: Map<String, String>, body: ByteArray): HttpResponse {
        val connection = URL(url).openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "POST"
            connection.connectTimeout = connectTimeoutMs
            connection.readTimeout = readTimeoutMs
            connection.useCaches = false
            connection.doOutput = true
            connection.setFixedLengthStreamingMode(body.size)
            headers.forEach { (name, value) -> connection.setRequestProperty(name, value) }

            connection.outputStream.use { it.write(body) }

            val status = connection.responseCode
            // Error bodies (4xx/5xx) come from errorStream; they carry the `error.code` we act on.
            val stream: InputStream? = if (status >= 400) connection.errorStream else connection.inputStream
            val text = stream?.use { it.readBytes().toString(Charsets.UTF_8) } ?: ""
            // Only Retry-After is read today (event queue backoff).
            val headers = connection.getHeaderField("Retry-After")?.let { mapOf("Retry-After" to it) } ?: emptyMap()
            return HttpResponse(status, text, headers)
        } finally {
            connection.disconnect()
        }
    }
}
