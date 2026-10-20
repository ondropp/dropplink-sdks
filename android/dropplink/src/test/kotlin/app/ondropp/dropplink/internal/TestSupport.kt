package app.ondropp.dropplink.internal

import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.util.concurrent.Executor

/** Reads a fixture from the shared `contract/` folder (path set by the Gradle test task). */
internal object Contract {
    private val dir: File by lazy {
        val path = System.getProperty("dropplink.contractDir") ?: "../../contract"
        File(path).also { require(it.isDirectory) { "contract dir not found at ${it.absolutePath}" } }
    }

    fun text(relativePath: String): String = File(dir, relativePath).readText(Charsets.UTF_8)

    fun json(relativePath: String): JSONObject = JSONObject(text(relativePath))
}

/** Runs tasks only when asked, so tests control ordering. */
internal class QueueExecutor : Executor {
    private val tasks = ArrayDeque<Runnable>()
    override fun execute(command: Runnable) {
        tasks.addLast(command)
    }

    fun runAll() {
        while (tasks.isNotEmpty()) tasks.removeFirst().run()
    }

    val size: Int get() = tasks.size
}

internal object DirectExecutor : Executor {
    override fun execute(command: Runnable) = command.run()
}

internal class RecordedRequest(val url: String, val headers: Map<String, String>, val body: ByteArray) {
    val json: JSONObject get() = JSONObject(body.toString(Charsets.UTF_8))
}

/** Replies with scripted responses in order; `null` in the script means a network error. */
internal class FakeHttpClient(vararg script: Pair<Int, String>?) : HttpClient {
    private val script = ArrayDeque(script.toList())
    val requests = mutableListOf<RecordedRequest>()

    fun enqueue(status: Int, body: String) = script.addLast(status to body)

    override fun post(url: String, headers: Map<String, String>, body: ByteArray): HttpResponse {
        requests += RecordedRequest(url, headers, body)
        check(script.isNotEmpty()) { "Unexpected request to $url" }
        val next = script.removeFirst() ?: throw IOException("connection reset")
        return HttpResponse(next.first, next.second)
    }
}

internal class FakeEnvironment(
    var referrer: InstallReferrer? = InstallReferrer.fromRaw(
        raw = "utm_source=dropp&click_id=c_8b1f0e7d2a4c4f6e",
        referrerClickTs = 1760700000,
        installBeginTs = 1760700042,
    ),
) : Environment {
    var referrerReads = 0
    override val appVersion = "3.2.1"
    override fun deviceInfo() = DeviceInfo(
        model = "Pixel 8",
        osVersion = "15",
        locale = "en-IN",
        timezone = "Asia/Kolkata",
        screen = Screen(1080, 2400, 2.625),
    )

    override fun readInstallReferrer(): InstallReferrer? {
        referrerReads++
        return referrer
    }
}

internal fun errorBody(code: String, message: String = code) =
    """{"error":{"code":"$code","message":"$message"}}"""
