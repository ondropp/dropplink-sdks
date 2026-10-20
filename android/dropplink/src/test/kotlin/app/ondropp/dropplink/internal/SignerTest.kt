package app.ondropp.dropplink.internal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Spec section 10.1: reproduce every signature in contract/hmac/vectors.json. */
class SignerTest {

    @Test
    fun reproducesEveryContractVector() {
        val vectors = Contract.json("hmac/vectors.json")
        val secret = vectors.getString("secret")
        val cases = vectors.getJSONArray("cases")
        assertTrue("no vectors found", cases.length() > 0)

        for (i in 0 until cases.length()) {
            val case = cases.getJSONObject(i)
            val name = case.getString("name")
            val body = case.getString("body").toByteArray(Charsets.UTF_8)
            val timestamp = case.getString("timestamp")

            assertEquals("$name bodySha256", case.getString("bodySha256"), Signer.sha256Hex(body))
            assertEquals("$name signingString", case.getString("signingString"), Signer.signingString(timestamp, body))
            assertEquals("$name signature", case.getString("signature"), Signer.sign(secret, timestamp, body))
        }
    }
}
