package app.ondropp.dropplink

import android.app.Application
import android.content.Context
import android.net.Uri
import android.util.Log
import app.ondropp.dropplink.internal.AppBackgroundWatcher
import app.ondropp.dropplink.internal.DeepLinkDispatcher
import app.ondropp.dropplink.internal.DropplinkCore
import app.ondropp.dropplink.internal.EventQueue
import app.ondropp.dropplink.internal.ExecutorScheduler
import app.ondropp.dropplink.internal.LogcatSink
import app.ondropp.dropplink.internal.Logger
import app.ondropp.dropplink.internal.MainThreadExecutor
import app.ondropp.dropplink.internal.AndroidEnvironment
import app.ondropp.dropplink.internal.Storage
import app.ondropp.dropplink.internal.UrlConnectionHttpClient
import app.ondropp.dropplink.internal.isDebuggable
import app.ondropp.dropplink.internal.queueFile
import app.ondropp.dropplink.internal.storageFile
import app.ondropp.dropplink.internal.validateConfig
import java.util.concurrent.Executors

/**
 * Dropplink: install attribution, deep links, in-app events and users.
 *
 * ```
 * // Application.onCreate
 * Dropplink.initialize(this, DropplinkConfig(keyId = BuildConfig.DROPPLINK_KEY_ID, secret = BuildConfig.DROPPLINK_SECRET))
 * Dropplink.setDeepLinkListener { link -> router.open(link.path, link.params) }
 *
 * // Launcher activity's onCreate and onNewIntent
 * intent?.data?.let { Dropplink.handleDeepLink(it) }
 *
 * // Anywhere
 * Dropplink.track("add_to_cart", mapOf("sku" to "TSHIRT-M"))
 * Dropplink.identify("user_8812")
 * ```
 *
 * No call throws (except [initialize] on a bad config in a debuggable build) or blocks on the network.
 */
public object Dropplink {

    /** The SDK version. Wrappers report `"$VERSION-flutter"` / `"$VERSION-rn"` to the server. */
    public const val VERSION: String = "0.2.0"

    private const val MAX_EARLY_LINKS = 10
    private const val MAX_EARLY_CALLS = 100

    // The dispatcher exists before initialize() so a listener can be set in any order.
    private val dispatcher = DeepLinkDispatcher(MainThreadExecutor)

    private val lock = Any()
    private var initializeCalled = false
    private val earlyLinks = ArrayList<String>()

    // track / identify / logout / setTrackingEnabled made before initialize(), replayed in order once the
    // core exists (an app may record consent before it initializes the SDK).
    private val earlyCalls = ArrayList<(DropplinkCore) -> Unit>()
    private var earlyTrackingEnabled: Boolean? = null
    private var initializeFailed = false

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
            synchronized(lock) {
                initializeFailed = true
                earlyLinks.clear()
                earlyCalls.clear()
            }
            if (isDebuggable(appContext)) throw IllegalArgumentException("Invalid DropplinkConfig: $problem")
            return
        }

        try {
            val logger = Logger(config.debug)
            // One thread for the network (init, deep links, queue flushes and their timers), one for queue writes.
            val network = Executors.newSingleThreadScheduledExecutor { runnable ->
                Thread(runnable, "Dropplink").apply { isDaemon = true }
            }
            val newCore = DropplinkCore(
                config = config,
                storage = Storage(storageFile(appContext)),
                http = UrlConnectionHttpClient(),
                environment = AndroidEnvironment(appContext, logger),
                dispatcher = dispatcher,
                logger = logger,
                background = network,
                queue = EventQueue(queueFile(appContext), logger) { System.currentTimeMillis() / 1000 },
                io = Executors.newSingleThreadExecutor { runnable ->
                    Thread(runnable, "Dropplink-io").apply { isDaemon = true }
                },
                scheduler = ExecutorScheduler(network),
            )
            // Queue init before publishing the core, so no deep link can be sent ahead of it.
            newCore.start()
            (appContext as? Application)?.registerActivityLifecycleCallbacks(AppBackgroundWatcher(newCore::onBackground))
            val (links, calls) = synchronized(lock) {
                core = newCore
                (earlyLinks.toList() to earlyCalls.toList()).also {
                    earlyLinks.clear()
                    earlyCalls.clear()
                }
            }
            calls.forEach { it(newCore) }
            links.forEach(newCore::handleDeepLink)
        } catch (t: Throwable) {
            synchronized(lock) {
                initializeFailed = true
                earlyCalls.clear()
            }
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

    /**
     * Records an in-app event: checked, written to the on-disk queue and sent in the background (batched,
     * retried until the server has it). Invalid events are dropped, with the reason logged in debug mode.
     *
     * Revenue sent from the app is shown as app-reported. Purchases that pay creators must be sent from
     * your server (`/v1/s2s/events`); use `track` for the funnel.
     *
     * @param name snake_case, e.g. `add_to_cart`.
     * @param props Up to 20 non-personal values: strings (up to 256 characters), numbers, booleans or null.
     *   Values that look like an email or a phone number are dropped.
     */
    @JvmStatic
    @JvmOverloads
    public fun track(name: String, props: Map<String, Any?>? = null, revenue: Revenue? = null) {
        val atMs = System.currentTimeMillis()
        // Copy now: the app may reuse its map after the call returns.
        val propsCopy = props?.let { LinkedHashMap(it) }
        withCore { it.track(name, propsCopy, revenue, atMs) }
    }

    /**
     * Links your own user id to this install, when the user signs up or logs in. Pass an opaque id, not an
     * email or phone number. [email] and [phone] (E.164, e.g. `+919876543210`) are optional and only their
     * SHA-256 hashes leave the device. Calling it again with the same user id does nothing, so it's fine
     * on every launch.
     */
    @JvmStatic
    @JvmOverloads
    public fun identify(userId: String, email: String? = null, phone: String? = null) {
        withCore { it.identify(userId, email, phone) }
    }

    /** Unlinks the user, when they log out. Events after it carry no user. */
    @JvmStatic
    public fun logout() {
        withCore { it.logout() }
    }

    /**
     * `false` (e.g. when the user declines tracking) clears the event queue and stops [track], [identify]
     * and [logout] until it is set back to `true`. Persisted across launches. Install attribution and deep
     * links keep working. Default `true`.
     */
    @JvmStatic
    public fun setTrackingEnabled(enabled: Boolean) {
        val current = synchronized(lock) {
            core ?: run {
                // Always kept, even past the cap: a consent choice must never be lost.
                if (!initializeFailed) {
                    earlyTrackingEnabled = enabled
                    earlyCalls.add { it.setTrackingEnabled(enabled) }
                }
                null
            }
        }
        safely { current?.setTrackingEnabled(enabled) }
    }

    /** Whether events and identify are recorded. Before [initialize], reflects only calls made this launch. */
    @JvmStatic
    public fun isTrackingEnabled(): Boolean =
        safely { core?.isTrackingEnabled } ?: synchronized(lock) { earlyTrackingEnabled } ?: true

    private fun withCore(call: (DropplinkCore) -> Unit) {
        val current = synchronized(lock) {
            core ?: run {
                // Before (or during) initialize(): hold the call. After a failed initialize(), drop it.
                if (!initializeFailed && earlyCalls.size < MAX_EARLY_CALLS) earlyCalls.add(call)
                null
            }
        }
        safely { current?.let(call) }
    }

    private inline fun <T> safely(block: () -> T?): T? = try {
        block()
    } catch (t: Throwable) {
        Log.e(LogcatSink.TAG, "Dropplink error", t)
        null
    }
}
