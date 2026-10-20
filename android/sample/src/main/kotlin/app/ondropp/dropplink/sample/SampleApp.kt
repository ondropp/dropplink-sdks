package app.ondropp.dropplink.sample

import android.app.Application
import app.ondropp.dropplink.DeepLink
import app.ondropp.dropplink.Dropplink
import app.ondropp.dropplink.DropplinkConfig

class SampleApp : Application() {

    override fun onCreate() {
        super.onCreate()

        // 1. Initialize as early as possible. Keys come from BuildConfig (see sample/build.gradle.kts).
        Dropplink.initialize(
            this,
            DropplinkConfig(
                keyId = BuildConfig.DROPPLINK_KEY_ID,
                secret = BuildConfig.DROPPLINK_SECRET,
                debug = BuildConfig.DEBUG, // Logcat tag "Dropplink"
                baseUrl = BuildConfig.DROPPLINK_BASE_URL,
            ),
        )

        // 2. One listener for both deferred links (fresh install) and App Link opens. Runs on the main thread.
        Dropplink.setDeepLinkListener { link ->
            lastDeepLink = link
            onDeepLinkChanged?.invoke(link)
        }
    }

    companion object {
        // A real app would route here (e.g. navController.navigate(link.path)); the sample just shows it.
        var lastDeepLink: DeepLink? = null
        var onDeepLinkChanged: ((DeepLink) -> Unit)? = null
    }
}
