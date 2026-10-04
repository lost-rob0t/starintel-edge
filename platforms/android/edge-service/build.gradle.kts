plugins { id("com.android.library") }
android {
    namespace = "actor.starintel.edge.service"
    compileSdk = 36
    buildToolsVersion = "36.0.0"
    defaultConfig { minSdk = 26 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

// Consume only an explicitly supplied, already built runtime bundle. No fetch/install task.
val edgeRuntimeRoot = providers.gradleProperty("starintel.edge.runtimeRoot").orNull
// Use the public AGP 9 DSL type. The legacy generated `android` accessor can
// infer AndroidLibrarySourceSet and cast a new-DSL source set to that old type.
extensions.configure<com.android.build.api.dsl.LibraryExtension> {
    sourceSets.named("main") {
        kotlin.directories += "../kotlin" // Built-in Kotlin needs its own source set.
        if (!edgeRuntimeRoot.isNullOrBlank()) {
            jniLibs.directories += "$edgeRuntimeRoot/jni"
            assets.directories += "$edgeRuntimeRoot/assets"
        }
    }
}
