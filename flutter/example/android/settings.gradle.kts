pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }

    // Gradle refuses to mix Android Gradle plugin versions in one composite build. When the native
    // SDK is built from source (see the bottom of this file), use the AGP version from its version
    // catalog instead of the one in `plugins {}` below.
    val sdkCatalog = file("../../../android/gradle/libs.versions.toml")
    val useLocalSdk = providers.gradleProperty("dropplink.useLocalSdk").getOrElse("true").toBoolean()
    val sdkAgpVersion =
        if (useLocalSdk && sdkCatalog.exists()) {
            Regex("""(?m)^\s*agp\s*=\s*"([^"]+)"""").find(sdkCatalog.readText())?.groupValues?.get(1)
        } else {
            null
        }
    if (sdkAgpVersion != null) {
        resolutionStrategy {
            eachPlugin {
                if (requested.id.id.startsWith("com.android.")) useVersion(sdkAgpVersion)
            }
        }
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
}

include(":app")

// Monorepo development: build the native SDK from ../../../android (dropplink-sdks/android) instead of
// downloading app.ondropp:dropplink-android from Maven, so plugin and SDK changes are tested together.
// On by default when that folder exists; turn off with `dropplink.useLocalSdk=false` in
// gradle.properties. `dropplink.localSdkProject` is the SDK library's project path in that build.
// Apps outside this repo don't need any of this.
val localDropplinkSdk = file("../../../android")
val useLocalDropplinkSdk = providers.gradleProperty("dropplink.useLocalSdk").getOrElse("true").toBoolean()
if (useLocalDropplinkSdk && (localDropplinkSdk.resolve("settings.gradle.kts").exists() || localDropplinkSdk.resolve("settings.gradle").exists())) {
    val sdkProject = providers.gradleProperty("dropplink.localSdkProject").getOrElse(":dropplink")
    includeBuild(localDropplinkSdk) {
        // The plugin's own Gradle project is also called "dropplink"; give the included build a distinct name.
        name = "dropplink-android-sdk"
        dependencySubstitution {
            substitute(module("app.ondropp:dropplink-android")).using(project(sdkProject))
        }
    }
}
