package app.ondropp.dropplink.internal

import app.ondropp.dropplink.DropplinkConfig
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class ConfigValidationTest {

    @Test
    fun acceptsAValidConfig() {
        assertNull(validateConfig(DropplinkConfig("ak_3f9c1e2a7b6d4c80", "secret")))
        assertNull(validateConfig(DropplinkConfig("ak_3f9c1e2a7b6d4c80", "secret", baseUrl = "http://10.0.2.2:4100")))
    }

    @Test
    fun rejectsBadKeysAndSecrets() {
        assertNotNull(validateConfig(DropplinkConfig("", "secret")))
        assertNotNull(validateConfig(DropplinkConfig("sk_3f9c1e2a7b6d4c80", "secret")))
        assertNotNull(validateConfig(DropplinkConfig("ak_3f9c1e2a7b6d4c80", " ")))
        assertNotNull(validateConfig(DropplinkConfig("ak_3f9c1e2a7b6d4c80", "secret", baseUrl = "ftp://x")))
    }

    @Test
    fun toStringNeverShowsTheSecret() {
        assertFalse(DropplinkConfig("ak_1", "very-secret").toString().contains("very-secret"))
    }
}
