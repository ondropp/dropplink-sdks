import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
    `maven-publish`
    signing
}

group = "app.ondropp"
version = "0.2.0" // Keep in sync with Dropplink.VERSION.

android {
    namespace = "app.ondropp.dropplink"
    compileSdk = 35

    defaultConfig {
        minSdk = 21
        consumerProguardFiles("consumer-rules.pro")
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    lint {
        abortOnError = true
    }

    publishing {
        singleVariant("release") {
            withSourcesJar()
            withJavadocJar()
        }
    }
}

kotlin {
    // Everything public must say so explicitly: the public surface is spec section 2 and nothing else.
    explicitApi()
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(libs.installreferrer)

    testImplementation(libs.junit)
    testImplementation(libs.org.json)
}

// Tests read the wire fixtures straight from ../contract so there is exactly one copy of them.
val contractDir = rootProject.layout.projectDirectory.dir("../contract").asFile
tasks.withType<Test>().configureEach {
    systemProperty("dropplink.contractDir", contractDir.absolutePath)
    inputs.dir(contractDir).withPropertyName("contract")
}

publishing {
    publications {
        register<MavenPublication>("release") {
            groupId = "app.ondropp"
            artifactId = "dropplink-android"
            version = project.version.toString()

            afterEvaluate { from(components["release"]) }

            pom {
                name.set("Dropplink Android SDK")
                description.set("Install attribution and deferred deep links for apps using Dropplink.")
                url.set("https://ondropp.app")
                licenses {
                    license {
                        name.set("The Apache License, Version 2.0")
                        url.set("https://www.apache.org/licenses/LICENSE-2.0.txt")
                    }
                }
                developers {
                    developer {
                        id.set("ondropp")
                        name.set("Dropp")
                        email.set("dev@ondropp.app")
                    }
                }
                scm {
                    url.set("https://github.com/ondropp/dropplink-sdks")
                    connection.set("scm:git:https://github.com/ondropp/dropplink-sdks.git")
                    developerConnection.set("scm:git:ssh://git@github.com/ondropp/dropplink-sdks.git")
                }
            }
        }
    }
    repositories {
        // `./gradlew :dropplink:publishReleasePublicationToStagingRepository` writes a Maven layout here,
        // which is zipped and uploaded to the Maven Central Portal.
        maven {
            name = "staging"
            url = uri(layout.buildDirectory.dir("staging-repo"))
        }
    }
}

signing {
    // Only sign when keys are provided, so local builds and CI tests work without them.
    val signingKey = findProperty("signingKey") as String?
    val signingPassword = findProperty("signingPassword") as String?
    isRequired = signingKey != null
    if (signingKey != null) {
        useInMemoryPgpKeys(signingKey, signingPassword)
        sign(publishing.publications)
    }
}
