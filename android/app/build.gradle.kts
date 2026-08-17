plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.ktlint)
}

// The control domain is the one value baked in at build time; everything else
// comes from https://{CONTROL_DOMAIN}/config.json at runtime (see
// kit's ConfigService). The repo is public, so the real domain never appears
// here — set `cabalmail.controlDomain` in ~/.gradle/gradle.properties (or pass
// -Pcabalmail.controlDomain=...) to point a local build at a live environment.
val controlDomain: String =
    providers.gradleProperty("cabalmail.controlDomain").getOrElse("admin.example.com")

android {
    namespace = "com.cabalmail.android"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.cabalmail.android"
        minSdk = 31
        targetSdk = 36
        // CI overrides both from the release pipeline (Phase 2): versionCode
        // from github.run_number, versionName from CHANGELOG.md.
        versionCode = 1
        versionName = "0.1.0"
        buildConfigField("String", "CONTROL_DOMAIN", "\"$controlDomain\"")
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
        }
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

dependencies {
    implementation(project(":kit"))

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material3)

    debugImplementation(libs.androidx.compose.ui.tooling)
}
