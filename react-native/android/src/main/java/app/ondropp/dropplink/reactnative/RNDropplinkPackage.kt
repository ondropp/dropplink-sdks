package app.ondropp.dropplink.reactnative

import com.facebook.react.BaseReactPackage
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.module.model.ReactModuleInfo
import com.facebook.react.module.model.ReactModuleInfoProvider

/** Picked up by React Native autolinking. */
class RNDropplinkPackage : BaseReactPackage() {
    override fun getModule(name: String, reactContext: ReactApplicationContext): NativeModule? =
        if (name == RNDropplinkModule.NAME) RNDropplinkModule(reactContext) else null

    override fun getReactModuleInfoProvider() = ReactModuleInfoProvider {
        mapOf(
            RNDropplinkModule.NAME to ReactModuleInfo(
                name = RNDropplinkModule.NAME,
                className = RNDropplinkModule::class.java.name,
                canOverrideExistingModule = false,
                needsEagerInit = false,
                isCxxModule = false,
                // Classic module, served through the New Architecture's interop layer.
                isTurboModule = false,
            ),
        )
    }
}
