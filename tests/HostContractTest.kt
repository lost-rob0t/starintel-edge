package actor.starintel.edge

fun main() {
    val seen = mutableListOf<Pair<String, HostRequest>>()
    val port = object : CommonLispPort {
        override fun request(platform: String, request: HostRequest): String {
            seen.add(Pair(platform, request))
            return "forwarded"
        }
    }
    val hosts = listOf(AndroidRuntimeHost(port), WatchRuntimeHost(port),
        AndroidGlassesHost(port), CompanionGlassesHost(port), MetaGlassesCompanionHost(port))
    val expected = listOf("android", "wearos", "android-glasses", "glasses-companion", "meta-companion")
    val payload = "{\"@type\":\"Observation\",\"value\":\"#.(not-code)\"}"
    val request = HostRequest(HostOperation.DISPATCH, payload, "camera.photo")
    hosts.forEachIndexed { index, host ->
        check(host.request(request) == "forwarded")
        check(seen.last() == Pair(expected[index], request))
        check(seen.last().second === request)
    }
    var unavailable = false
    try { AndroidRuntimeHost().request(HostRequest(HostOperation.START)) }
    catch (_: RuntimeUnavailableException) { unavailable = true }
    check(unavailable)
    check(HostOperation.values().map { it.wireName }.toSet().size == 6)
    println("17 Kotlin facade checks passed; not an Android/ABCL/device test.")
}
