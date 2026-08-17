plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.ktlint)
    alias(libs.plugins.triplet.play)
}

// The control domain is the one value baked in at build time; everything else
// comes from https://{CONTROL_DOMAIN}/config.json at runtime (see
// kit's ConfigService). The repo is public, so the real domain never appears
// here — set `cabalmail.controlDomain` in ~/.gradle/gradle.properties (or pass
// -Pcabalmail.controlDomain=...) to point a local build at a live environment.
val controlDomain: String =
    providers.gradleProperty("cabalmail.controlDomain").getOrElse("admin.example.com")

// CI signing (android.yml upload job): the workflow decodes the upload
// keystore to a temp file and passes everything via environment. When
// KEYSTORE_PATH is absent — every local and PR build — release stays unsigned
// (Play App Signing holds the distribution key; this keystore only signs the
// upload artifact).
val keystorePath: String? = System.getenv("KEYSTORE_PATH")

android {
    namespace = "com.cabalmail.android"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.cabalmail.android"
        minSdk = 31
        targetSdk = 36
        // CI overrides both (android.yml upload job): versionCode from
        // github.run_number — Play only needs a monotonically increasing
        // integer, but that means a workflow *rename* resets it; if that ever
        // happens, offset the expression in the workflow rather than renaming
        // back. versionName tracks the newest CHANGELOG.md release, matching
        // apple.yml's marketing version.
        versionCode = System.getenv("VERSION_CODE")?.toIntOrNull() ?: 1
        versionName = System.getenv("VERSION_NAME") ?: "0.1.0"
        buildConfigField("String", "CONTROL_DOMAIN", "\"$controlDomain\"")
    }

    signingConfigs {
        if (keystorePath != null) {
            create("upload") {
                storeFile = file(keystorePath)
                storePassword = System.getenv("KEYSTORE_PASSWORD")
                keyAlias = System.getenv("KEY_ALIAS")
                keyPassword = System.getenv("KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            // R8 stays off until Phase 7 (baseline profiles + full mode land
            // together, with keep rules written against real usage).
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            if (keystorePath != null) {
                signingConfig = signingConfigs.getByName("upload")
            }
        }
    }

    testOptions {
        unitTests.all {
            it.useJUnitPlatform()
        }
    }

    lint {
        // The Phase 2 gate: a lint warning is a CI failure, so drift never
        // accumulates. Suppressions must be explicit and justified in-line.
        warningsAsErrors = true
        // Version freshness belongs to dependabot (gradle ecosystem,
        // .github/dependabot.yml); failing CI whenever upstream ships a
        // release would be noise, not signal.
        disable += listOf("AndroidGradlePluginVersion", "GradleDependency", "NewerVersionAvailable")
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

play {
    // Credentials arrive via the ANDROID_PUBLISHER_CREDENTIALS environment
    // variable (the raw service-account JSON), which the plugin reads
    // natively; without it the plugin is disabled so local builds and PR CI
    // never touch (or require) Play credentials.
    enabled.set(System.getenv("ANDROID_PUBLISHER_CREDENTIALS") != null)
    track.set("internal")
    defaultToAppBundles.set(true)
}

dependencies {
    implementation(project(":kit"))

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.androidx.datastore.preferences)
    implementation(libs.ktor.client.okhttp)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material3)
    implementation(libs.coil.compose)
    implementation(libs.coil.network.okhttp)

    debugImplementation(libs.androidx.compose.ui.tooling)

    testImplementation(libs.junit.jupiter)
    testRuntimeOnly(libs.junit.platform.launcher)
}
