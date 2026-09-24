package actor.starintel.edge

/** Typed host facades only: no Android service, ABCL loader, or actor engine yet. */
enum class HostOperation(val wireName: String) {
    STATUS("status"), START("start"), SUSPEND("suspend"),
    RESUME("resume"), STOP("stop"), DISPATCH("dispatch")
}

data class HostRequest(
    val operation: HostOperation,
    val payloadJsonLd: String? = null,
    val capability: String? = null
)

/** Implement with the canonical Lisp ABI. Never turn request data into eval text. */
interface CommonLispPort {
    fun request(platform: String, request: HostRequest): String
}

class RuntimeUnavailableException : IllegalStateException("Common Lisp runtime is not attached")

object UnavailableCommonLispPort : CommonLispPort {
    override fun request(platform: String, request: HostRequest): String {
        throw RuntimeUnavailableException()
    }
}

/** Native lifecycle and permission callbacks belong in the installed platform adapter.
 * This facade forwards data; Lisp owns lifecycle, policy and execution semantics.
 */
open class PlatformHost(val platform: String, private val port: CommonLispPort) {
    fun request(request: HostRequest): String = port.request(platform, request)
}

class AndroidRuntimeHost(port: CommonLispPort = UnavailableCommonLispPort) :
    PlatformHost("android", port)
