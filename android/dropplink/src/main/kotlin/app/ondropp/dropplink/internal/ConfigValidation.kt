package app.ondropp.dropplink.internal

import app.ondropp.dropplink.DropplinkConfig

/** Returns what's wrong with [config], or `null` if it's usable (spec section 5, last paragraph). */
internal fun validateConfig(config: DropplinkConfig): String? = when {
    config.keyId.isBlank() -> "keyId is empty"
    !config.keyId.startsWith("ak_") ->
        "keyId must start with \"ak_\" (use the SDK key id from the dashboard, not the server token)"
    config.secret.isBlank() -> "secret is empty"
    !config.baseUrl.startsWith("https://") && !config.baseUrl.startsWith("http://") ->
        "baseUrl must start with http:// or https://"
    else -> null
}
