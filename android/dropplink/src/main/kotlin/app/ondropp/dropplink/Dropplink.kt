package app.ondropp.dropplink

import android.content.Context
import android.net.Uri
import android.util.Log
import app.ondropp.dropplink.internal.DeepLinkDispatcher
import app.ondropp.dropplink.internal.DropplinkCore
import app.ondropp.dropplink.internal.LogcatSink
import app.ondropp.dropplink.internal.Logger
import app.ondropp.dropplink.internal.MainThreadExecutor
import app.ondropp.dropplink.internal.AndroidEnvironment
import app.ondropp.dropplink.internal.Storage
import app.ondropp.dropplink.internal.UrlConnectionHttpClient
import app.ondropp.dropplink.internal.isDebuggable
import app.ondropp.dropplink.internal.storageFile
import app.ondropp.dropplink.internal.validateConfig
import java.util.concurrent.Executors

/**
 * Dropplink: install attribution and deep links.
 *
 * ```
 * // Application.onCreate
 * Dropplink.initialize(this, DropplinkConfig(keyId = BuildConfig.DROPPLINK_KEY_ID, secret = BuildConfig.DROPPLINK_SECRET))
 * Dropplink.setDeepLinkListener { link -> router.open(link.path, link.params) }
 *
 * // Launcher activity's onCreate and onNewIntent
 * intent?.data?.let { Dropplink.handleDeepLink(it) }
 * ```
 *
 * No call throws (except [initialize] on a bad config in a debuggable build) or blocks on the network.
 */
public object Dropplink {

    /** The SDK version. Wrappers report `"$VERSION-flutter"` / `"$VERSION-rn"` to the server. */
    public const val VERSION: String = "0.1.0"

    private const val MAX_EARLY_LINKS = 10

    // The dispatcher exists before initialize() so a listener can be set in any order.
    private val dispatcher = DeepLinkDispatcher(MainThreadExecutor)

    private val lock = Any()
    private var initializeCalled = false
    private val earlyLinks = ArrayList<String>()

    @Volatile
    private var core: DropplinkCore? = null

    /**
     * Starts the SDK and sends `/v1/init` in the background. Call once, from `Application.onCreate`.
     * Later calls are ignored.
     *
     * @throws IllegalArgumentException only if [config] is invalid **and** the app is debuggable, so the
     *   mistake is caught during development. In release builds the SDK logs an error and stays off.
     */
    @JvmStatic
    public fun initialize(context: Context, config: DropplinkConfig) {
        synchronized(lock) {
            if (initializeCalled) return
            initializeCalled = true
        }
        val appContext = context.applicationContext ?: context

        val problem = validateConfig(config)
        if (problem != null) {
            // Logged even with debug = false: the SDK is off, and the developer needs to know why.
            Log.e(LogcatSink.TAG, "Invalid DropplinkConfig: $problem. Dropplink is disabled.")
            synchronized(lock) { earlyLinks.clear() }
            if (isDebuggable(appContext)) throw IllegalArgumentException("Invalid DropplinkConfig: $problem")
            return
        }

        try {
            val logger = Logger(config.debug)
            val newCore = DropplinkCore(
                config = config,
                storage = Storage(storageFile(appContext)),
                http = UrlConnectionHttpClient(),
                environment = AndroidEnvironment(appContext, logger),
                dispatcher = dispatcher,
                logger = logger,
                background = Executors.newSingleThreadExecutor { runnable ->
                    Thread(runnable, "Dropplink").apply { isDaemon = true }
                },
            )
            // Queue init before publishing the core, so no deep link can be sent ahead of it.
            newCore.start()
            val queued = synchronized(lock) {
                core = newCore
                earlyLinks.toList().also { earlyLinks.clear() }
            }
            queued.forEach(newCore::handleDeepLink)
        } catch (t: Throwable) {
            Log.e(LogcatSink.TAG, "Dropplink failed to start", t)
        }
    }

    /**
     * Receives every deep link on the main thread: the deferred one after a fresh install and App Link
     * opens. A link that arrived before a listener was set is delivered as soon as one is. Pass `null`
     * to remove the listener.
     */
    @JvmStatic
    public fun setDeepLinkListener(listener: DeepLinkListener?) {
        dispatcher.setListener(listener)
    }

    /**
     * Reports an App Link the app was opened with (`intent.data`), from the launcher activity's
     * `onCreate` and `onNewIntent`. Non-http(s) URIs are ignored.
     */
    @JvmStatic
    public fun handleDeepLink(uri: Uri) {
        handleDeepLink(uri.toString())
    }

    /** Same as [handleDeepLink] with a [Uri], for callers that hold a string (e.g. the RN and Flutter bridges). */
    @JvmStatic
    public fun handleDeepLink(url: String) {
        if (!DropplinkCore.isHttpUrl(url)) return
        val current = synchronized(lock) {
            core ?: run {
                // Before initialize(): hold the link and send it once init is queued. After a failed
                // initialize() (bad config), drop it.
                if (!initializeCalled && earlyLinks.size < MAX_EARLY_LINKS) earlyLinks.add(url)
                null
            }
        }
        current?.handleDeepLink(url)
    }

    /** The last attribution the server returned, or `null` before the first successful init. */
    @JvmStatic
    public fun getAttribution(): Attribution? = safely { core?.attribution }

    /** This install's id, for the dashboard's Install debugger. `null` before [initialize]. */
    @JvmStatic
    public fun getInstallId(): String? = safely { core?.installId }

    private inline fun <T> safely(block: () -> T?): T? = try {
        block()
    } catch (t: Throwable) {
        Log.e(LogcatSink.TAG, "Dropplink error", t)
        null
    }
}
