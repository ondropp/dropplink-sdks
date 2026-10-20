package app.ondropp.dropplink.internal

import android.content.Context
import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerStateListener
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * Reads the Play Install Referrer synchronously on the SDK's background thread.
 *
 * The library is callback-based (callbacks arrive on the main thread), so we wait on a latch with a
 * timeout. Any failure returns `null`: init is then sent without a referrer and the next launch tries again.
 */
internal class InstallReferrerReader(
    private val context: Context,
    private val logger: Logger,
    private val timeoutMs: Long = 5_000,
) {

    fun read(): InstallReferrer? {
        val client = try {
            InstallReferrerClient.newBuilder(context).build()
        } catch (t: Throwable) {
            logger.warn("Install Referrer unavailable: $t")
            return null
        }
        try {
            val responseCode = AtomicInteger(NO_RESPONSE)
            val done = CountDownLatch(1)
            client.startConnection(object : InstallReferrerStateListener {
                override fun onInstallReferrerSetupFinished(code: Int) {
                    responseCode.compareAndSet(NO_RESPONSE, code)
                    done.countDown()
                }

                override fun onInstallReferrerServiceDisconnected() {
                    done.countDown()
                }
            })
            if (!done.await(timeoutMs, TimeUnit.MILLISECONDS)) {
                logger.warn("Install Referrer timed out; will retry next launch")
                return null
            }
            val code = responseCode.get()
            if (code != InstallReferrerClient.InstallReferrerResponse.OK) {
                logger.warn("Install Referrer not available (code $code); will retry next launch")
                return null
            }
            val details = client.installReferrer
            val raw = details.installReferrer ?: return null
            return InstallReferrer.fromRaw(
                raw = raw,
                referrerClickTs = details.referrerClickTimestampSeconds,
                installBeginTs = details.installBeginTimestampSeconds,
            )
        } catch (t: Throwable) {
            logger.warn("Install Referrer failed: $t; will retry next launch")
            return null
        } finally {
            try {
                client.endConnection()
            } catch (_: Throwable) {
            }
        }
    }

    private companion object {
        const val NO_RESPONSE = Int.MIN_VALUE
    }
}
