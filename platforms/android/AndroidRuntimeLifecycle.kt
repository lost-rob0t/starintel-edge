package actor.starintel.edge

/**
 * Android-only lifecycle coordinator for the shared Common Lisp runtime.
 *
 * This class does not implement actor semantics, collection, sync, or durable queues.
 * It serializes platform lifecycle decisions and forwards only typed lifecycle
 * operations to AndroidRuntimeHost. The installed Android adapter owns the actual
 * Service/foreground APIs and supplies FOREGROUND_ALLOWED from current OS state.
 */
enum class AndroidRuntimeState {
    STOPPED,
    BLOCKED,
    RUNNING,
    SUSPENDED,
    FAILED
}

enum class AndroidRuntimeFailure {
    RUNTIME_UNAVAILABLE,
    BACKEND_FAILURE
}

enum class AndroidRuntimeBlocker {
    FOREGROUND_NOT_ALLOWED
}

/**
 * Persist only the user's desired local-runtime state in app-private storage.
 * Credentials, pairing secrets, mission payloads, and collected data do not belong here.
 */
interface AndroidRuntimeStateStore {
    fun desiredRun(): Boolean
    fun setDesiredRun(desired: Boolean)
}

/** Test/default helper. Production Android code must bind an app-private durable store. */
class InMemoryAndroidRuntimeStateStore(initialDesiredRun: Boolean = false) :
    AndroidRuntimeStateStore {
    private var desired = initialDesiredRun

    @Synchronized
    override fun desiredRun(): Boolean = desired

    @Synchronized
    override fun setDesiredRun(desired: Boolean) {
        this.desired = desired
    }
}

data class AndroidRuntimeDiagnostics(
    val state: AndroidRuntimeState,
    val desiredRun: Boolean,
    val sessionStarted: Boolean,
    val transitionCount: Long,
    val failureCount: Long,
    val lastFailure: AndroidRuntimeFailure?,
    val blocker: AndroidRuntimeBlocker?
)

class AndroidRuntimeLifecycle(
    private val host: AndroidRuntimeHost,
    private val stateStore: AndroidRuntimeStateStore
) {
    private var state = AndroidRuntimeState.STOPPED
    private var sessionStarted = false
    private var transitionCount = 0L
    private var failureCount = 0L
    private var lastFailure: AndroidRuntimeFailure? = null
    private var blocker: AndroidRuntimeBlocker? = null

    @Synchronized
    fun start(foregroundAllowed: Boolean): AndroidRuntimeDiagnostics {
        stateStore.setDesiredRun(true)
        return startInternal(foregroundAllowed)
    }

    /**
     * Reconcile after process creation. A persisted desire to run is not treated as
     * proof that a runtime survived process death; a new START is required.
     */
    @Synchronized
    fun restore(foregroundAllowed: Boolean): AndroidRuntimeDiagnostics {
        if (!stateStore.desiredRun()) {
            return diagnosticsInternal()
        }
        return startInternal(foregroundAllowed)
    }

    @Synchronized
    fun suspend(): AndroidRuntimeDiagnostics {
        if (!sessionStarted || state != AndroidRuntimeState.RUNNING) {
            return diagnosticsInternal()
        }
        return requestTransition(HostOperation.SUSPEND, AndroidRuntimeState.SUSPENDED)
    }

    @Synchronized
    fun resume(foregroundAllowed: Boolean): AndroidRuntimeDiagnostics {
        stateStore.setDesiredRun(true)
        if (!foregroundAllowed) {
            blockForForeground()
            return diagnosticsInternal()
        }
        if (state == AndroidRuntimeState.RUNNING) {
            clearTransientStatus()
            return diagnosticsInternal()
        }
        if (!sessionStarted) {
            return startInternal(true)
        }
        return requestTransition(HostOperation.RESUME, AndroidRuntimeState.RUNNING)
    }

    /**
     * Called by an Android Service/activity adapter when platform policy requires
     * local execution to pause in the background. No Android API is hidden here.
     */
    @Synchronized
    fun onBackgroundRestriction(requiresSuspend: Boolean): AndroidRuntimeDiagnostics {
        if (requiresSuspend) {
            return suspend()
        }
        return diagnosticsInternal()
    }

    @Synchronized
    fun stop(): AndroidRuntimeDiagnostics {
        stateStore.setDesiredRun(false)
        blocker = null
        if (!sessionStarted) {
            transitionTo(AndroidRuntimeState.STOPPED)
            lastFailure = null
            return diagnosticsInternal()
        }

        try {
            host.request(HostRequest(HostOperation.STOP))
            sessionStarted = false
            lastFailure = null
            transitionTo(AndroidRuntimeState.STOPPED)
        } catch (_: RuntimeUnavailableException) {
            recordFailure(AndroidRuntimeFailure.RUNTIME_UNAVAILABLE)
        } catch (_: RuntimeException) {
            recordFailure(AndroidRuntimeFailure.BACKEND_FAILURE)
        }
        return diagnosticsInternal()
    }

    @Synchronized
    fun diagnostics(): AndroidRuntimeDiagnostics = diagnosticsInternal()

    private fun startInternal(foregroundAllowed: Boolean): AndroidRuntimeDiagnostics {
        if (sessionStarted && (state == AndroidRuntimeState.RUNNING ||
                    state == AndroidRuntimeState.SUSPENDED)) {
            return diagnosticsInternal()
        }
        if (!foregroundAllowed) {
            blockForForeground()
            return diagnosticsInternal()
        }

        try {
            host.request(HostRequest(HostOperation.START))
            sessionStarted = true
            clearTransientStatus()
            transitionTo(AndroidRuntimeState.RUNNING)
        } catch (_: RuntimeUnavailableException) {
            sessionStarted = false
            recordFailure(AndroidRuntimeFailure.RUNTIME_UNAVAILABLE)
        } catch (_: RuntimeException) {
            sessionStarted = false
            recordFailure(AndroidRuntimeFailure.BACKEND_FAILURE)
        }
        return diagnosticsInternal()
    }

    private fun requestTransition(
        operation: HostOperation,
        successState: AndroidRuntimeState
    ): AndroidRuntimeDiagnostics {
        try {
            host.request(HostRequest(operation))
            clearTransientStatus()
            transitionTo(successState)
        } catch (_: RuntimeUnavailableException) {
            recordFailure(AndroidRuntimeFailure.RUNTIME_UNAVAILABLE)
        } catch (_: RuntimeException) {
            recordFailure(AndroidRuntimeFailure.BACKEND_FAILURE)
        }
        return diagnosticsInternal()
    }

    private fun blockForForeground() {
        blocker = AndroidRuntimeBlocker.FOREGROUND_NOT_ALLOWED
        lastFailure = null
        transitionTo(AndroidRuntimeState.BLOCKED)
    }

    private fun clearTransientStatus() {
        blocker = null
        lastFailure = null
    }

    private fun recordFailure(failure: AndroidRuntimeFailure) {
        blocker = null
        lastFailure = failure
        failureCount += 1
        transitionTo(AndroidRuntimeState.FAILED)
    }

    private fun transitionTo(next: AndroidRuntimeState) {
        if (state != next) {
            state = next
            transitionCount += 1
        }
    }

    private fun diagnosticsInternal(): AndroidRuntimeDiagnostics =
        AndroidRuntimeDiagnostics(
            state = state,
            desiredRun = stateStore.desiredRun(),
            sessionStarted = sessionStarted,
            transitionCount = transitionCount,
            failureCount = failureCount,
            lastFailure = lastFailure,
            blocker = blocker
        )
}
