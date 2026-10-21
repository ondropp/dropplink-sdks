package app.ondropp.dropplink.internal

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
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

    /** File names in a fixture folder, sorted. */
    fun list(relativeDir: String): List<String> =
        File(dir, relativeDir).listFiles()?.map { it.name }?.sorted().orEmpty()
}

/** Same keys everywhere, same values; numbers compared by value (2.625 may parse as Double or BigDecimal). */
internal fun assertSameJson(path: String, expected: Any, actual: Any) {
    when (expected) {
        is JSONObject -> {
            assertTrue("$path is not an object", actual is JSONObject)
            actual as JSONObject
            assertEquals("keys at '$path'", expected.keys().asSequence().toSet(), actual.keys().asSequence().toSet())
            for (key in expected.keys()) assertSameJson("$path/$key", expected.get(key), actual.get(key))
        }
        is JSONArray -> {
            assertTrue("$path is not an array", actual is JSONArray)
            actual as JSONArray
            assertEquals("length of '$path'", expected.length(), actual.length())
            for (i in 0 until expected.length()) assertSameJson("$path[$i]", expected.get(i), actual.get(i))
        }
        is Number -> {
            assertTrue("$path is not a number", actual is Number)
            assertEquals(path, expected.toDouble(), (actual as Number).toDouble(), 0.0)
        }
        else -> assertEquals(path, expected, actual)
    }
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
    private val script = ArrayDeque(script.map { it?.let { (status, body) -> HttpResponse(status, body) } })
    val requests = mutableListOf<RecordedRequest>()

    fun enqueue(status: Int, body: String, headers: Map<String, String> = emptyMap()) =
        script.addLast(HttpResponse(status, body, headers))

    fun enqueueNetworkError() = script.addLast(null)

    override fun post(url: String, headers: Map<String, String>, body: ByteArray): HttpResponse {
        requests += RecordedRequest(url, headers, body)
        check(script.isNotEmpty()) { "Unexpected request to $url" }
        return script.removeFirst() ?: throw IOException("connection reset")
    }
}

/** A [Scheduler] on a virtual clock: tasks run only when the test calls [advance]. */
internal class FakeScheduler {
    var nowMs = 0L
        private set
    private val tasks = mutableListOf<Pair<Long, Runnable>>()
    val scheduler = Scheduler { delayMs, task -> tasks += (nowMs + delayMs) to task }

    /** Delays of everything scheduled so far that hasn't run yet. */
    val pendingDelays: List<Long> get() = tasks.map { it.first - nowMs }

    fun advance(ms: Long) {
        val until = nowMs + ms
        while (true) {
            val next = tasks.filter { it.first <= until }.minByOrNull { it.first } ?: break
            tasks.remove(next)
            nowMs = next.first
            next.second.run()
        }
        nowMs = until
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
