package actor.interop

import actor.starintel.edge.StarIntelEdgeRuntime

/** Kotlin uses the production singleton unchanged; there is no native stub. */
object KotlinActorClient {
    @JvmStatic
    fun main(args: Array<String>) {
        val runtime = StarIntelEdgeRuntime
        println("ACTOR_ABI\t${runtime.abiVersion()}")
        check(runtime.start(args[0]) == null) { "real ECL startup failed" }
        try {
            System.`in`.bufferedReader(Charsets.UTF_8).forEachLine {
                println("ACTOR_RESULT\t${runtime.request(it)}")
            }
            var checks = 0
            for (bad in listOf("x\u0000y", "\uD800", "\uDC00", "\uD800a")) {
                val response = runtime.request("{\"op\":\"dispatch\",\"payload\":\"$bad\",\"capability\":\"interop.echo\"}")
                check(response.contains("malformed-request")) { response }
                checks++
            }
            check(checks == 4)
        } finally { runtime.stop() }
        check(runtime.request("{\"op\":\"runtime.ping\"}").contains("not-started"))
        check(runtime.start(args[0]) == "process-restart-required")
        println("ACTOR_CLIENT_CHECKS\t6")
    }
}
