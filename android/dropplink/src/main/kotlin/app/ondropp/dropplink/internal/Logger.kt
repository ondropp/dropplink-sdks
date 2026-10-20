package app.ondropp.dropplink.internal

import android.util.Log

internal enum class LogLevel { DEBUG, WARN, ERROR }

internal fun interface LogSink {
    fun log(level: LogLevel, message: String)
}

/** Writes to Logcat under the `Dropplink` tag. */
internal object LogcatSink : LogSink {
    const val TAG = "Dropplink"

    override fun log(level: LogLevel, message: String) {
        when (level) {
            LogLevel.DEBUG -> Log.d(TAG, message)
            LogLevel.WARN -> Log.w(TAG, message)
            LogLevel.ERROR -> Log.e(TAG, message)
        }
    }
}

/**
 * Debug-only logging (spec section 8): silent unless `debug = true`.
 * Never pass the secret, a signature or a full request body to it.
 */
internal class Logger(private val enabled: Boolean, private val sink: LogSink = LogcatSink) {
    fun debug(message: String) = write(LogLevel.DEBUG, message)
    fun warn(message: String) = write(LogLevel.WARN, message)
    fun error(message: String) = write(LogLevel.ERROR, message)

    private fun write(level: LogLevel, message: String) {
        if (enabled) sink.log(level, message)
    }
}
