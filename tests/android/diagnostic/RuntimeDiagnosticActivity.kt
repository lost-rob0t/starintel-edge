package actor.starintel.edge.diagnostic

import android.app.Activity
import android.graphics.Color
import android.os.Bundle
import android.util.Log
import android.view.Gravity
import android.widget.TextView
import actor.starintel.edge.StarIntelEdgeRuntime
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

class RuntimeDiagnosticActivity : Activity() {
    private lateinit var status: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        status = TextView(this).apply {
            setBackgroundColor(Color.rgb(5, 10, 15))
            setTextColor(Color.rgb(219, 238, 244))
            textSize = 18f
            gravity = Gravity.CENTER
            setPadding(48, 48, 48, 48)
            text = "STARINTEL EDGE // ANDROID RUNTIME\n\nStarting trusted Common Lisp runtime…"
        }
        setContentView(status)
        currentActivity = this
        val completed = lastResult
        if (completed != null) {
            status.text = "STARINTEL EDGE // ANDROID RUNTIME\n\n$completed"
        } else if (running.compareAndSet(false, true)) {
            Thread({ runDiagnostic() }, "starintel-edge-diagnostic").start()
        }
    }

    override fun onDestroy() {
        if (currentActivity === this) currentActivity = null
        super.onDestroy()
    }

    private fun runDiagnostic() {
        var nativeRuntimeLoaded = false
        val result = try {
            val runtimeDirectory = File(filesDir, "starintel-edge")
            runtimeDirectory.deleteRecursively()
            copyAssetTree("starintel-edge", runtimeDirectory)

            check(StarIntelEdgeRuntime.abiVersion() == 1) { "unexpected adapter ABI" }
            nativeRuntimeLoaded = true
            StarIntelEdgeRuntime.start(runtimeDirectory.absolutePath)?.let { stableError ->
                val detail = File(runtimeDirectory, "lisp/startup-error.txt")
                    .takeIf(File::isFile)?.readText()?.trim()
                error(listOfNotNull(stableError, detail).joinToString(": "))
            }

            val ping = StarIntelEdgeRuntime.request("{\"op\":\"runtime.ping\"}")
            check(ping.contains("\"status\":\"ok\"")) { "runtime ping failed: $ping" }
            val actor = StarIntelEdgeRuntime.request("{\"op\":\"actor.roundtrip\"}")
            check(actor.contains("\"status\":\"ok\"")) { "actor round-trip failed: $actor" }
            check(actor.contains("\"message\":\"android-local\"")) {
                "actor response was not local: $actor"
            }
            val catalog = StarIntelEdgeRuntime.request("{\"op\":\"actor.list\"}")
            check(catalog.contains("\"id\":\"runtime.echo\"")) {
                "trusted actor catalog unavailable: $catalog"
            }
            val dispatch = StarIntelEdgeRuntime.request(
                "{\"op\":\"actor.dispatch\",\"payload\":\"{\\\"actor_id\\\":\\\"runtime.echo\\\",\\\"message\\\":{}}\"}",
            )
            check(dispatch.contains("\"ok\":true")) { "actor dispatch failed: $dispatch" }

            "PASS\n\nECL booted inside ART\nAdapter ABI 1\nManaged Sento runtime started\nClosed actor catalog + dispatch passed\nNo network permission requested"
        } catch (failure: Throwable) {
            Log.e(TAG, "Runtime diagnostic failed", failure)
            "FAIL\n\n${failure.javaClass.simpleName}: ${failure.message}"
        } finally {
            if (nativeRuntimeLoaded) StarIntelEdgeRuntime.stop()
        }

        Log.i(TAG, result.replace('\n', ' '))
        lastResult = result
        currentActivity?.let { activity ->
            activity.runOnUiThread {
                activity.status.text = "STARINTEL EDGE // ANDROID RUNTIME\n\n$result"
            }
        }
    }

    private fun copyAssetTree(assetPath: String, destination: File) {
        val children = assets.list(assetPath) ?: emptyArray()
        if (children.isEmpty()) {
            destination.parentFile?.mkdirs()
            assets.open(assetPath).use { input ->
                destination.outputStream().use { output -> input.copyTo(output) }
            }
            return
        }
        destination.mkdirs()
        children.forEach { child ->
            copyAssetTree("$assetPath/$child", File(destination, child))
        }
    }

    companion object {
        private const val TAG = "StarIntelEdgeDiagnostic"
        private val running = AtomicBoolean(false)
        @Volatile private var lastResult: String? = null
        @Volatile private var currentActivity: RuntimeDiagnosticActivity? = null
    }
}
