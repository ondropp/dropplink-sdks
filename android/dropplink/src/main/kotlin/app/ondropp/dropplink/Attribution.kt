package app.ondropp.dropplink

/**
 * How this install was attributed, as last returned by the server.
 *
 * @property type `"attributed"` or `"organic"`.
 * @property method `"install_referrer"`, `"fingerprint"` or `"none"`.
 * @property confidence 1.0 for Install Referrer matches, the match score for fingerprint matches.
 * @property attributedAt ISO 8601 time the server attributed the install.
 */
public data class Attribution(
    public val type: String,
    public val method: String,
    public val clickId: String?,
    public val linkId: String?,
    public val campaignId: String?,
    public val creatorId: String?,
    public val source: String?,
    public val confidence: Double?,
    public val attributedAt: String?,
) {
    /** Plain map for the Flutter and React Native bridges. */
    public fun toMap(): Map<String, Any?> = mapOf(
        "type" to type,
        "method" to method,
        "clickId" to clickId,
        "linkId" to linkId,
        "campaignId" to campaignId,
        "creatorId" to creatorId,
        "source" to source,
        "confidence" to confidence,
        "attributedAt" to attributedAt,
    )
}
