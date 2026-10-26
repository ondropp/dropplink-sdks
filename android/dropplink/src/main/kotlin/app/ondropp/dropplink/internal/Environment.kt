package app.ondropp.dropplink.internal

/** Everything the core needs from the device. The Android implementation is [AndroidEnvironment]. */
internal interface Environment {
    val appVersion: String
    fun deviceInfo(): DeviceInfo

    /** Blocks the calling (background) thread. `null` if the API failed or isn't available. */
    fun readInstallReferrer(): InstallReferrer?

    /** Opens [url] in a browser, never in this app. `false` if no browser could be started. */
    fun openInBrowser(url: String): Boolean
}
