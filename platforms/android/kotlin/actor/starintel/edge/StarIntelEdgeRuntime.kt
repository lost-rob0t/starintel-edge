package actor.starintel.edge

/**
 * Thin process-owned binding to the reusable StarIntel Edge runtime.
 * Product code owns asset extraction and Android lifecycle integration; this
 * binding owns no Activity, Service, permission, network, or UI behavior.
 */
object StarIntelEdgeRuntime {
    init {
        System.loadLibrary("ecl")
        System.loadLibrary("lmdb")
        System.loadLibrary("starintel_ecl_adapter")
        System.loadLibrary("starintel_ecl_jni")
    }

    external fun abiVersion(): Int

    /** Returns null on success or a stable error string on failure. */
    external fun start(runtimeDirectory: String): String?

    /** Returns one bounded JSON response owned by the managed caller. */
    external fun request(requestJson: String): String

    external fun stop()
}
