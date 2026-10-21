package app.ondropp.dropplink.flutter

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import app.ondropp.dropplink.Dropplink
import app.ondropp.dropplink.DropplinkConfig
import app.ondropp.dropplink.Revenue
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * Flutter bridge to the native Dropplink Android SDK (`app.ondropp:dropplink-android`).
 *
 * Holds no logic of its own: it forwards Dart calls to [Dropplink], streams the SDK's deep links to
 * Dart, and forwards the App Link the activity was opened with (launch intent and `onNewIntent`) to
 * [Dropplink.handleDeepLink], so apps get App Links without writing native code.
 *
 * Automatic forwarding can be turned off with
 * `<meta-data android:name="app.ondropp.dropplink.auto_handle_links" android:value="false" />`
 * in the app's `<application>`, for apps that call `Dropplink.handleDeepLink` from Dart themselves.
 */
class DropplinkPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    PluginRegistry.NewIntentListener {

    private lateinit var context: Context
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private val mainHandler = Handler(Looper.getMainLooper())
    private var activityBinding: ActivityPluginBinding? = null
    private var autoHandleLinks = true

    // Links the OS opened the app with before Dart called initialize(). The native SDK needs a
    // config before it can resolve them, so they wait here (in memory only) until then.
    private val linksBeforeInit = mutableListOf<String>()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        autoHandleLinks = readAutoHandleLinks(context)
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL)
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL)
        eventChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        Dropplink.setDeepLinkListener(null)
    }

    // region MethodChannel

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initialize" -> initialize(call, result)
            "handleDeepLink" -> {
                val url = call.argument<String>("url")
                if (url == null) {
                    result.error("invalid_argument", "url is required", null)
                } else {
                    Dropplink.handleDeepLink(url)
                    result.success(null)
                }
            }
            "getAttribution" -> result.success(Dropplink.getAttribution()?.toMap())
            "getInstallId" -> result.success(Dropplink.getInstallId())
            "track" -> track(call, result)
            "identify" -> {
                val userId = call.argument<String>("userId")
                if (userId == null) {
                    result.error("invalid_argument", "userId is required", null)
                } else {
                    Dropplink.identify(userId, call.argument<String>("email"), call.argument<String>("phone"))
                    result.success(null)
                }
            }
            "logout" -> {
                Dropplink.logout()
                result.success(null)
            }
            "setTrackingEnabled" -> {
                val enabled = call.argument<Boolean>("enabled")
                if (enabled == null) {
                    result.error("invalid_argument", "enabled is required", null)
                } else {
                    Dropplink.setTrackingEnabled(enabled)
                    result.success(null)
                }
            }
            "isTrackingEnabled" -> result.success(Dropplink.isTrackingEnabled())
            else -> result.notImplemented()
        }
    }

    private fun track(call: MethodCall, result: MethodChannel.Result) {
        val name = call.argument<String>("name")
        if (name == null) {
            result.error("invalid_argument", "name is required", null)
            return
        }
        // Values arrive as String, Boolean, Int/Long, Double or null and are passed on as they are: the
        // native SDK validates them (spec section 11). The codec decodes into a HashMap, so Dart's
        // insertion order (used by the "first 20 props" cap) is already lost by the time we get here.
        val props = call.argument<Map<*, *>>("props")?.let { raw ->
            LinkedHashMap<String, Any?>(raw.size).apply {
                raw.forEach { (key, value) -> if (key is String) put(key, value) }
            }
        }
        val revenue = call.argument<Map<*, *>>("revenue")?.let { raw ->
            val amount = (raw["amount"] as? Number)?.toDouble()
            val currency = raw["currency"] as? String
            if (amount == null || currency == null) {
                result.error("invalid_argument", "revenue needs amount and currency", null)
                return
            }
            Revenue(amount = amount, currency = currency, orderId = raw["orderId"] as? String)
        }
        Dropplink.track(name, props, revenue)
        result.success(null)
    }

    private fun initialize(call: MethodCall, result: MethodChannel.Result) {
        val keyId = call.argument<String>("keyId").orEmpty()
        val secret = call.argument<String>("secret").orEmpty()
        val debug = call.argument<Boolean>("debug") ?: false
        val baseUrl = call.argument<String>("baseUrl")
        val config = if (baseUrl != null) {
            DropplinkConfig(
                keyId = keyId,
                secret = secret,
                debug = debug,
                baseUrl = baseUrl,
                platformWrapper = PLATFORM_WRAPPER,
            )
        } else {
            DropplinkConfig(keyId = keyId, secret = secret, debug = debug, platformWrapper = PLATFORM_WRAPPER)
        }
        try {
            Dropplink.initialize(context, config)
        } catch (e: Exception) {
            // Config validation is the only thing the native SDK throws for (spec section 5).
            result.error("invalid_config", e.message, null)
            return
        }
        initialized = true
        linksBeforeInit.forEach(Dropplink::handleDeepLink)
        linksBeforeInit.clear()
        result.success(null)
    }

    // endregion

    // region EventChannel

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        // Setting the listener makes the native SDK deliver any link it was holding.
        Dropplink.setDeepLinkListener { link ->
            val map = link.toMap()
            if (Looper.myLooper() == Looper.getMainLooper()) {
                events.success(map)
            } else {
                mainHandler.post { events.success(map) }
            }
        }
    }

    override fun onCancel(arguments: Any?) {
        Dropplink.setDeepLinkListener(null)
    }

    // endregion

    // region ActivityAware: forward App Links

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        attach(binding)
        val intent = binding.activity.intent
        // Re-launching from Recents replays the original intent; that link was already handled.
        if (intent != null && intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY == 0) {
            forwardLink(intent)
        }
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        // Same intent as before the rotation etc.; don't forward it twice.
        attach(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() = detach()

    override fun onDetachedFromActivity() = detach()

    override fun onNewIntent(intent: Intent): Boolean {
        forwardLink(intent)
        // Not consumed: other plugins (app_links, uni_links, …) still see the intent.
        return false
    }

    private fun attach(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addOnNewIntentListener(this)
    }

    private fun detach() {
        activityBinding?.removeOnNewIntentListener(this)
        activityBinding = null
    }

    private fun forwardLink(intent: Intent) {
        if (!autoHandleLinks || intent.action != Intent.ACTION_VIEW) return
        val uri = intent.data ?: return
        if (uri.scheme != "http" && uri.scheme != "https") return
        val url = uri.toString()
        if (initialized) Dropplink.handleDeepLink(url) else linksBeforeInit += url
    }

    // endregion

    private fun readAutoHandleLinks(context: Context): Boolean = try {
        @Suppress("DEPRECATION")
        val info = context.packageManager.getApplicationInfo(context.packageName, PackageManager.GET_META_DATA)
        info.metaData?.getBoolean(META_AUTO_HANDLE_LINKS, true) ?: true
    } catch (e: Exception) {
        Log.w(TAG, "Couldn't read $META_AUTO_HANDLE_LINKS; forwarding App Links automatically", e)
        true
    }

    private companion object {
        const val TAG = "Dropplink"
        const val METHOD_CHANNEL = "app.ondropp.dropplink/methods"
        const val EVENT_CHANNEL = "app.ondropp.dropplink/deeplinks"
        const val PLATFORM_WRAPPER = "flutter"
        const val META_AUTO_HANDLE_LINKS = "app.ondropp.dropplink.auto_handle_links"

        // Process-wide, like the native SDK: a second engine (e.g. a background isolate) must not
        // hold links back again after the first engine initialized.
        @Volatile
        var initialized = false
    }
}
