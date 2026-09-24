package actor.starintel.edge

/** Use only where installation and the Common Lisp backend have been verified. */
class AndroidGlassesHost(port: CommonLispPort = UnavailableCommonLispPort) :
    PlatformHost("android-glasses", port)

/** Runtime executes on the phone/compute host, not the paired display accessory. */
class CompanionGlassesHost(port: CommonLispPort = UnavailableCommonLispPort) :
    PlatformHost("glasses-companion", port)

/** Official DAT integration belongs behind this port. No vendor SDK is bundled yet.
 * Camera/display/input capabilities must come from the actual device and SDK session.
 */
class MetaGlassesCompanionHost(port: CommonLispPort = UnavailableCommonLispPort) :
    PlatformHost("meta-companion", port)
