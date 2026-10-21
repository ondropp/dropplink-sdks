package app.ondropp.dropplink

/**
 * Money attached to an event, for [Dropplink.track]. Shown in the dashboard as **app-reported**: revenue
 * that pays creators must come from your server (`/v1/s2s/events`).
 *
 * @property amount At least 0. More than 2 decimals are rounded half-up.
 * @property currency ISO 4217 code such as `"INR"` or `"USD"` (case and surrounding spaces don't matter).
 * @property orderId Your order id, up to 128 characters.
 */
public data class Revenue @JvmOverloads constructor(
    public val amount: Double,
    public val currency: String,
    public val orderId: String? = null,
)
