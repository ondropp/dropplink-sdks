group = "app.ondropp.dropplink.flutter"
version = "0.2.1"

buildscript {
    val kotlinVersion = "2.2.20"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:8.11.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
    id("kotlin-android")
}

android {
    // Not "app.ondropp.dropplink": that namespace belongs to the native SDK.
    namespace = "app.ondropp.dropplink.flutter"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
    }

    defaultConfig {
        minSdk = 21
    }
}

dependencies {
    // All logic lives in the native SDK. Inside the dropplink-sdks repo the example app swaps this for
    // ../android built from source (see example/android/settings.gradle.kts).
    implementation("app.ondropp:dropplink-android:0.2.1")
}
