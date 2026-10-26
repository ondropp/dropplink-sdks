package app.ondropp.dropplink.internal

import android.app.Activity
import android.app.Application
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import java.io.File
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.Executor

internal class AndroidEnvironment(
    private val context: Context,
    logger: Logger,
) : Environment {

    private val referrerReader = InstallReferrerReader(context, logger)

    override val appVersion: String by lazy {
        try {
            val pm = context.packageManager
            val info = if (Build.VERSION.SDK_INT >= 33) {
                pm.getPackageInfo(context.packageName, PackageManager.PackageInfoFlags.of(0))
            } else {
                @Suppress("DEPRECATION")
                pm.getPackageInfo(context.packageName, 0)
            }
            info.versionName ?: "unknown"
        } catch (e: Exception) {
            "unknown"
        }
    }

    override fun deviceInfo(): DeviceInfo {
        val metrics = context.resources.displayMetrics
        return DeviceInfo(
            model = Build.MODEL ?: "unknown",
            osVersion = Build.VERSION.RELEASE ?: "unknown",
            locale = Locale.getDefault().toLanguageTag(),
            timezone = TimeZone.getDefault().id,
            screen = Screen(w = metrics.widthPixels, h = metrics.heightPixels, dpr = metrics.density.toDouble()),
        )
    }

    override fun readInstallReferrer(): InstallReferrer? = referrerReader.read()

    /**
     * Targets a browser package explicitly: a plain VIEW intent could resolve back to this app (or another
     * one) through App Links. Finding browsers needs the `<queries>` entry in the SDK's manifest.
     */
    override fun openInBrowser(url: String): Boolean {
        val pm = context.packageManager
        val probe = Intent(Intent.ACTION_VIEW, Uri.parse("https://")).addCategory(Intent.CATEGORY_BROWSABLE)
        val isBrowser = { pkg: String? -> pkg != null && pkg != "android" && pkg != context.packageName }
        val browser = pm.resolveActivity(probe, PackageManager.MATCH_DEFAULT_ONLY)?.activityInfo?.packageName
            ?.takeIf(isBrowser)
            ?: pm.queryIntentActivities(probe, 0).map { it.activityInfo.packageName }.firstOrNull(isBrowser)
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
            .addCategory(Intent.CATEGORY_BROWSABLE)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (browser != null) intent.setPackage(browser)
        return try {
            context.startActivity(intent)
            true
        } catch (e: ActivityNotFoundException) {
            false
        }
    }
}

internal fun storageFile(context: Context): File = File(context.noBackupFilesDir, "dropplink.json")

internal fun queueFile(context: Context): File = File(context.noBackupFilesDir, "dropplink-queue.json")

/**
 * Calls [onBackground] when the last started activity stops, i.e. the app went to the background.
 * Counts started activities itself so the SDK needs no androidx.lifecycle dependency. A configuration
 * change (rotation) stops and restarts an activity, so it isn't counted as going to the background.
 * Callbacks arrive on the main thread.
 */
internal class AppBackgroundWatcher(private val onBackground: () -> Unit) : Application.ActivityLifecycleCallbacks {
    private var started = 0

    override fun onActivityStarted(activity: Activity) {
        started++
    }

    override fun onActivityStopped(activity: Activity) {
        if (started > 0) started--
        if (started == 0 && !activity.isChangingConfigurations) onBackground()
    }

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
    override fun onActivityResumed(activity: Activity) = Unit
    override fun onActivityPaused(activity: Activity) = Unit
    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
    override fun onActivityDestroyed(activity: Activity) = Unit
}

internal fun isDebuggable(context: Context): Boolean =
    (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0

/** Runs listener callbacks on the main thread. The Handler is created lazily, on first use. */
internal object MainThreadExecutor : Executor {
    private val handler by lazy { Handler(Looper.getMainLooper()) }
    override fun execute(command: Runnable) {
        handler.post(command)
    }
}
