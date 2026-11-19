plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    // For the app-layer `@Serializable` records (the resume session); the
    // kit module applies the same plugin for its models.
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.ktlint)
    alias(libs.plugins.triplet.play)
}

// The control domain is typed on the sign-in screen and remembered per
// install, like the Apple client; everything else comes from
// https://{control_domain}/config.json at runtime (see kit's ConfigService).
// This build-time value is only a developer convenience: it prefills the
// sign-in form (and keeps an existing debug session valid) on an install that
// has never signed in. Nothing baked in by default — the repo is public and CI
// builds must not point at any one deployment — set `cabalmail.controlDomain`
// in ~/.gradle/gradle.properties (or pass -Pcabalmail.controlDomain=...) for a
// local build.
val controlDomain: String =
    providers.gradleProperty("cabalmail.controlDomain").getOrElse("")

// Firebase client config for push (docs/1.x/android-push-notifications.md).
// Not secrets — these values ship inside every APK — but they are
// per-environment, so like the control domain nothing is baked in by
// default: set the cabalmail.fcm* properties in ~/.gradle/gradle.properties
// (values from the Firebase console's project settings). Any of the four
// blank — the default, and every CI build — leaves push wired off; the
// WorkManager poll carries notifications instead. There is deliberately no
// google-services plugin: FirebaseOptions are built manually from these
// fields (see notifications/Push.kt).
fun fcmProperty(name: String): String = providers.gradleProperty(name).getOrElse("")
val fcmProjectId = fcmProperty("cabalmail.fcmProjectId")
val fcmApplicationId = fcmProperty("cabalmail.fcmApplicationId")
val fcmApiKey = fcmProperty("cabalmail.fcmApiKey")
val fcmSenderId = fcmProperty("cabalmail.fcmSenderId")

// CI signing (android.yml upload job): the workflow decodes the upload
// keystore to a temp file and passes everything via environment. When
// KEYSTORE_PATH is absent — every local and PR build — release stays unsigned
// (Play App Signing holds the distribution key; this keystore only signs the
// upload artifact).
val keystorePath: String? = System.getenv("KEYSTORE_PATH")

android {
    namespace = "com.cabalmail.android"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.cabalmail.android"
        minSdk = 31
        targetSdk = 37
        // CI overrides both (android.yml upload job): versionCode starts from
        // github.run_number, and the publisher raises it when Play already
        // holds that code or a higher one (see `resolutionStrategy` in the
        // `play` block), so the code that ships can be above the run number.
        // A workflow *rename* resets the run number, which the same rule
        // absorbs. versionName tracks the newest CHANGELOG.md release,
        // matching apple.yml's marketing version.
        versionCode = System.getenv("VERSION_CODE")?.toIntOrNull() ?: 1
        versionName = System.getenv("VERSION_NAME") ?: "0.1.0"
        buildConfigField("String", "CONTROL_DOMAIN", "\"$controlDomain\"")
        buildConfigField("String", "FCM_PROJECT_ID", "\"$fcmProjectId\"")
        buildConfigField("String", "FCM_APPLICATION_ID", "\"$fcmApplicationId\"")
        buildConfigField("String", "FCM_API_KEY", "\"$fcmApiKey\"")
        buildConfigField("String", "FCM_SENDER_ID", "\"$fcmSenderId\"")
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
            // Plan §7.6: R8 (full mode is the default since AGP 8) with resource
            // shrinking; keep rules live in proguard-rules.pro. Baseline
            // profiles are still to come — see the Phase 7 PR.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            when {
                keystorePath != null -> signingConfig = signingConfigs.getByName("upload")
                // Local smoke-testing of the shrunk build: sign with the debug
                // key so it installs (`-Pcabalmail.debugSignRelease=true`).
                // Never set in CI; the unsigned artifact stays the default.
                providers.gradleProperty("cabalmail.debugSignRelease").isPresent ->
                    signingConfig = signingConfigs.getByName("debug")
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
    // Stage and main publish to this one track, and each run takes its
    // version code (the run number) when it starts. A main run then waits
    // for the gate-prod approval, so a stage run started meanwhile can
    // publish a higher code first, and Play refuses the lower one: "does
    // not allow any existing users to upgrade" (#2491, the 1.54.0
    // promotion). AUTO asks Play, while the bundle is built, for the highest
    // code on any track, and uses that plus one when ours is not above it;
    // a code that is already above it is left alone. The same rule makes a
    // re-run publishable: a re-run keeps its run number, which by then is
    // taken. Asking Play opens this run's edit, and Play keeps one open edit
    // per account, so two uploads must not overlap: android.yml's `upload`
    // job runs them one at a time (#2505), which also means two of them
    // cannot ask at once and pick the same code.
    resolutionStrategy.set(
        com.github.triplet.gradle.androidpublisher.ResolutionStrategy.AUTO,
    )
}

dependencies {
    implementation(project(":kit"))

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.androidx.datastore.preferences)
    implementation(libs.androidx.work.runtime.ktx)
    implementation(libs.androidx.webkit)
    implementation(libs.firebase.messaging)
    implementation(libs.play.services.base)
    implementation(libs.ktor.client.okhttp)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.material.icons.core)
    implementation(libs.androidx.compose.material3.adaptive.navigation.suite)
    implementation(libs.androidx.compose.material3.adaptive)
    implementation(libs.androidx.compose.material3.adaptive.layout)
    implementation(libs.androidx.compose.material3.adaptive.navigation)
    implementation(libs.coil.compose)
    implementation(libs.coil.network.okhttp)

    debugImplementation(libs.androidx.compose.ui.tooling)

    testImplementation(libs.junit.jupiter)
    // RulesViewModelTest drives viewModelScope on a test main dispatcher.
    testImplementation(libs.kotlinx.coroutines.test)
    testRuntimeOnly(libs.junit.platform.launcher)
}
