import java.util.Properties
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
}

// Keys come from android/local.properties (gitignored) or -P / ~/.gradle/gradle.properties:
//   dropplink.keyId=ak_...
//   dropplink.secret=...
val localProperties = Properties().apply {
    rootProject.file("local.properties").takeIf { it.exists() }?.inputStream()?.use { load(it) }
}
fun dropplinkProperty(name: String, fallback: String): String =
    (findProperty(name) as String?) ?: localProperties.getProperty(name) ?: fallback

android {
    namespace = "app.ondropp.dropplink.sample"
    compileSdk = 35

    defaultConfig {
        applicationId = "app.ondropp.dropplink.sample"
        minSdk = 21
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"

        buildConfigField("String", "DROPPLINK_KEY_ID", "\"${dropplinkProperty("dropplink.keyId", "ak_0000000000000000")}\"")
        buildConfigField("String", "DROPPLINK_SECRET", "\"${dropplinkProperty("dropplink.secret", "replace-me")}\"")
        buildConfigField("String", "DROPPLINK_BASE_URL", "\"${dropplinkProperty("dropplink.baseUrl", "https://attribution.ondropp.app")}\"")
    }

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(project(":dropplink"))
}
