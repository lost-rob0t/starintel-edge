plugins { id("com.android.application") }
android {
    namespace = "actor.starintel.edge.diagnostic"
    compileSdk = 36
    buildToolsVersion = "36.0.0"
    defaultConfig {
        applicationId = "actor.starintel.edge.diagnostic"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0-host-preview"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
dependencies { implementation(project(":edge-service")) }
