package app.ondropp.dropplink

/**
 * Settings for [Dropplink.initialize].
 *
 * @property keyId The `ak_…` SDK key id for this app's Android platform, from the Dropp dashboard.
 * @property secret The key's secret. Keep it in `BuildConfig`, never in source control.
 * @property debug Turns on logging under the `Dropplink` tag. Never ship `true`.
 * @property baseUrl The attribution server. Override only for local testing, e.g. `http://10.0.2.2:4100`.
 */
public data class DropplinkConfig @JvmOverloads constructor(
    public val keyId: String,
    public val secret: String,
    public val debug: Boolean = false,
    public val baseUrl: String = "https://attribution.ondropp.app",
    /** Set only by the Flutter ("flutter") and React Native ("rn") wrappers; sdkVersion becomes "0.1.0-<wrapper>". */
    public val platformWrapper: String? = null,
) {
    // A data class would print the secret in logs and crash reports; never let it.
    override fun toString(): String =
        "DropplinkConfig(keyId=$keyId, secret=***, debug=$debug, baseUrl=$baseUrl, platformWrapper=$platformWrapper)"
}
