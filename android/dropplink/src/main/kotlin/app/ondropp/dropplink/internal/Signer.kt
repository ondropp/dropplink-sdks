package app.ondropp.dropplink.internal

import java.security.MessageDigest
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Request signing (spec section 4):
 * `hex(HMAC_SHA256(key = UTF-8 secret, msg = timestamp + "\n" + hex(SHA256(body bytes))))`.
 *
 * Always sign the exact byte array that is sent; re-serializing the body after signing breaks the signature.
 */
internal object Signer {

    fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).toHex()

    fun signingString(timestamp: String, body: ByteArray): String = "$timestamp\n${sha256Hex(body)}"

    /** @param timestamp Unix time in **seconds**, as sent in `X-Timestamp`. */
    fun sign(secret: String, timestamp: String, body: ByteArray): String {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(secret.toByteArray(Charsets.UTF_8), "HmacSHA256"))
        return mac.doFinal(signingString(timestamp, body).toByteArray(Charsets.UTF_8)).toHex()
    }

    private fun ByteArray.toHex(): String {
        val digits = "0123456789abcdef"
        val out = StringBuilder(size * 2)
        for (b in this) {
            val v = b.toInt() and 0xff
            out.append(digits[v ushr 4]).append(digits[v and 0x0f])
        }
        return out.toString()
    }
}
