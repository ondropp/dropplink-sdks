package app.ondropp.dropplink.internal

import app.ondropp.dropplink.DeepLink
import app.ondropp.dropplink.DeepLinkListener
import java.util.concurrent.Executor

/**
 * Hands deep links to the app's listener on the main thread (spec section 7).
 *
 * A link that arrives with no listener set is held in memory (only the latest one, never persisted)
 * and delivered as soon as a listener is set.
 */
internal class DeepLinkDispatcher(private val mainThread: Executor) {
    private val lock = Any()
    private var listener: DeepLinkListener? = null
    private var pending: DeepLink? = null

    fun setListener(newListener: DeepLinkListener?) {
        val toDeliver = synchronized(lock) {
            listener = newListener
            if (newListener != null) pending.also { pending = null } else null
        }
        if (newListener != null && toDeliver != null) {
            mainThread.execute { newListener.onDeepLink(toDeliver) }
        }
    }

    fun deliver(link: DeepLink) {
        val current = synchronized(lock) {
            listener ?: run {
                pending = link
                null
            }
        }
        // The listener is the app's own code: an exception there is the app's bug and is not swallowed.
        current?.let { mainThread.execute { it.onDeepLink(link) } }
    }
}
