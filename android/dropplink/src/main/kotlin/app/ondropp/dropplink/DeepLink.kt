package app.ondropp.dropplink

/**
 * A deep link to route the user to.
 *
 * @property path Where to go in the app, e.g. `/product/123`.
 * @property params Extra values for the screen, e.g. `variant=red`.
 * @property url The App Link the app was opened with, or `null` for a deferred link.
 * @property isDeferred `true` only for the link delivered after a fresh install from a Dropplink link.
 */
public data class DeepLink(
    public val path: String,
    public val params: Map<String, String>,
    public val url: String?,
    public val isDeferred: Boolean,
) {
    /** Plain map for the Flutter and React Native bridges. */
    public fun toMap(): Map<String, Any?> = mapOf(
        "path" to path,
        "params" to params,
        "url" to url,
        "isDeferred" to isDeferred,
    )
}

/** Receives deep links on the main thread. See [Dropplink.setDeepLinkListener]. */
public fun interface DeepLinkListener {
    public fun onDeepLink(link: DeepLink)
}
