package app.ondropp.dropplink.sample

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.widget.ScrollView
import android.widget.TextView
import app.ondropp.dropplink.Dropplink

class MainActivity : Activity() {

    private lateinit var text: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        text = TextView(this).apply {
            setPadding(48, 48, 48, 48)
            setTextIsSelectable(true) // so the install id can be copied into the Install debugger
        }
        setContentView(ScrollView(this).apply { addView(text) })

        // 3. Report the App Link the app was opened with.
        intent?.data?.let { Dropplink.handleDeepLink(it) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        // singleTask: a link tapped while the app is open arrives here instead of onCreate.
        intent.data?.let { Dropplink.handleDeepLink(it) }
    }

    override fun onResume() {
        super.onResume()
        SampleApp.onDeepLinkChanged = { render() }
        render()
    }

    override fun onPause() {
        SampleApp.onDeepLinkChanged = null
        super.onPause()
    }

    private fun render() {
        val attribution = Dropplink.getAttribution()
        val link = SampleApp.lastDeepLink
        text.text = buildString {
            appendLine("Install id (paste into Install debugger):")
            appendLine(Dropplink.getInstallId() ?: "-")
            appendLine()
            appendLine("Attribution:")
            appendLine(attribution?.toMap()?.entries?.joinToString("\n") { "  ${it.key}: ${it.value}" } ?: "  none yet")
            appendLine()
            appendLine("Last deep link:")
            append(link?.let { "  ${it.path} ${it.params}\n  deferred=${it.isDeferred} url=${it.url}" } ?: "  none")
        }
    }
}
