package actor.starintel.edge

/** Watch-local target. This does not imply ABCL has passed on Wear OS ART.
 * Bind a verified local runtime; optional phone relay must be explicit in UI/status.
 */
class WatchRuntimeHost(port: CommonLispPort = UnavailableCommonLispPort) :
    PlatformHost("wearos", port)
