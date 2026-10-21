package app.ondropp.dropplink.internal

import app.ondropp.dropplink.Attribution
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class StorageTest {

    @get:Rule
    val tmp = TemporaryFolder()

    @Test
    fun roundTripsState() {
        val storage = Storage(tmp.root.resolve("dropplink.json"))
        val state = Storage.State(
            installId = "6f1c2a9e-3b7d-4c51-9a8e-2d4f6b1c0e73",
            attributed = true,
            attribution = Attribution("attributed", "fingerprint", "c_1", null, null, null, "instagram", 0.82, null),
        )
        storage.write(state)
        assertEquals(state, Storage(tmp.root.resolve("dropplink.json")).read())
    }

    @Test
    fun missingOrCorruptFileReadsAsEmpty() {
        val file = tmp.root.resolve("dropplink.json")
        assertEquals(Storage.State(), Storage(file).read())
        file.writeText("{not json")
        assertEquals(Storage.State(), Storage(file).read())
    }

    @Test
    fun trackingEnabledDefaultsToTrueAndIsStoredOnlyWhenOff() {
        val file = tmp.root.resolve("dropplink.json")
        file.writeText("""{"installId":"6f1c2a9e-3b7d-4c51-9a8e-2d4f6b1c0e73","attributed":false}""")
        assertEquals(true, Storage(file).read().trackingEnabled)

        Storage(file).write(Storage.State(installId = "x", trackingEnabled = false))
        assertEquals(false, Storage(file).read().trackingEnabled)
        Storage(file).write(Storage.State(installId = "x", trackingEnabled = true))
        assertEquals(false, file.readText().contains("trackingEnabled"))
    }
}
