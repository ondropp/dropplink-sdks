package app.ondropp.dropplink.reactnative

import app.ondropp.dropplink.DeepLink
import app.ondropp.dropplink.DeepLinkListener
import app.ondropp.dropplink.Dropplink
import app.ondropp.dropplink.DropplinkConfig
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.modules.core.DeviceEventManagerModule

/**
 * Thin bridge to the native Dropplink SDK. All behaviour (storage, signing, retries, pending-link
 * buffering) lives in `app.ondropp:dropplink-android`; this class only converts arguments.
 *
 * A classic native module: React Native 0.76+ serves it to JS through the TurboModule interop
 * layer under the New Architecture.
 */
class RNDropplinkModule(reactContext: ReactApplicationContext) :
    ReactContextBaseJavaModule(reactContext) {

    override fun getName(): String = NAME

    @ReactMethod
    fun initializeSdk(config: ReadableMap, promise: Promise) {
        try {
            val base = DropplinkConfig(
                keyId = config.stringOrNull("keyId").orEmpty(),
                secret = config.stringOrNull("secret").orEmpty(),
                debug = config.hasKey("debug") && !config.isNull("debug") && config.getBoolean("debug"),
                platformWrapper = PLATFORM_WRAPPER,
            )
            // Leave the SDK's default baseUrl in place unless JS passed one.
            val sdkConfig = config.stringOrNull("baseUrl")?.let { base.copy(baseUrl = it) } ?: base
            Dropplink.initialize(reactApplicationContext.applicationContext, sdkConfig)
            promise.resolve(null)
        } catch (e: Exception) {
            // The SDK only throws for invalid config in debug builds of the host app.
            promise.reject("dropplink_initialize_failed", e.message, e)
        }
    }

    @ReactMethod
    fun handleDeepLink(url: String, promise: Promise) {
        Dropplink.handleDeepLink(url)
        promise.resolve(null)
    }

    @ReactMethod
    fun getAttribution(promise: Promise) {
        promise.resolve(Dropplink.getAttribution()?.let { Arguments.makeNativeMap(it.toMap()) })
    }

    @ReactMethod
    fun getInstallId(promise: Promise) {
        promise.resolve(Dropplink.getInstallId())
    }

    /**
     * JS calls this with `true` when its first deep-link listener is added (the SDK then delivers
     * any link it buffered) and `false` when the last one is removed (the SDK buffers again).
     */
    @ReactMethod
    fun setDeepLinkListenerEnabled(enabled: Boolean) {
        Dropplink.setDeepLinkListener(if (enabled) DeepLinkListener { emitDeepLink(it) } else null)
    }

    // Required by NativeEventEmitter; subscription counting is done in JS.
    @ReactMethod
    fun addListener(@Suppress("UNUSED_PARAMETER") eventName: String) = Unit

    @ReactMethod
    fun removeListeners(@Suppress("UNUSED_PARAMETER") count: Double) = Unit

    override fun invalidate() {
        // JS context is going away (reload/teardown): let the SDK buffer links again.
        Dropplink.setDeepLinkListener(null)
        super.invalidate()
    }

    private fun emitDeepLink(link: DeepLink) {
        if (!reactApplicationContext.hasActiveReactInstance()) return
        reactApplicationContext
            .getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
            .emit(DEEP_LINK_EVENT, Arguments.makeNativeMap(link.toMap()))
    }

    private fun ReadableMap.stringOrNull(key: String): String? =
        if (hasKey(key) && !isNull(key)) getString(key) else null

    companion object {
        const val NAME = "RNDropplink"
        const val DEEP_LINK_EVENT = "DropplinkDeepLink"
        private const val PLATFORM_WRAPPER = "rn"
    }
}
