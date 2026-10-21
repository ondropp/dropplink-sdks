package app.ondropp.dropplink.internal

import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/** Runs a task later: the queue's 1 s debounce and its backoff. An interface so tests control time. */
internal fun interface Scheduler {
    fun schedule(delayMs: Long, task: Runnable)
}

internal class ExecutorScheduler(private val executor: ScheduledExecutorService) : Scheduler {
    override fun schedule(delayMs: Long, task: Runnable) {
        executor.schedule(task, delayMs, TimeUnit.MILLISECONDS)
    }
}
