package app.ondropp.dropplink.internal

import app.ondropp.dropplink.DeepLink
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Spec section 10.5: a pending deep link is delivered once a listener is set. */
class DeepLinkDispatcherTest {

    private val main = QueueExecutor()
    private val dispatcher = DeepLinkDispatcher(main)
    private fun link(path: String) = DeepLink(path, emptyMap(), null, true)

    @Test
    fun pendingLinkIsDeliveredWhenAListenerIsSet() {
        dispatcher.deliver(link("/a"))
        val received = mutableListOf<DeepLink>()
        dispatcher.setListener { received += it }
        main.runAll()

        assertEquals(listOf(link("/a")), received)
    }

    @Test
    fun onlyTheLatestPendingLinkIsKeptAndDeliveredOnce() {
        dispatcher.deliver(link("/old"))
        dispatcher.deliver(link("/new"))
        val received = mutableListOf<DeepLink>()
        dispatcher.setListener { received += it }
        dispatcher.setListener { received += it }
        main.runAll()

        assertEquals(listOf(link("/new")), received)
    }

    @Test
    fun linksGoThroughTheMainThreadExecutor() {
        val received = mutableListOf<DeepLink>()
        dispatcher.setListener { received += it }
        dispatcher.deliver(link("/a"))

        assertTrue(received.isEmpty())
        assertEquals(1, main.size)
        main.runAll()
        assertEquals(listOf(link("/a")), received)
    }

    @Test
    fun removingTheListenerHoldsLinksAgain() {
        val first = mutableListOf<DeepLink>()
        dispatcher.setListener { first += it }
        dispatcher.setListener(null)
        dispatcher.deliver(link("/a"))
        val second = mutableListOf<DeepLink>()
        dispatcher.setListener { second += it }
        main.runAll()

        assertTrue(first.isEmpty())
        assertEquals(listOf(link("/a")), second)
    }

    @Test
    fun deepLinkMapForTheBridges() {
        val map = DeepLink("/p", mapOf("a" to "1"), "https://x.y/z", false).toMap()
        assertEquals(mapOf("path" to "/p", "params" to mapOf("a" to "1"), "url" to "https://x.y/z", "isDeferred" to false), map)
    }
}
