- Android: **Targets Android API 37; build toolchain refresh.** The client
  now compiles against and targets API 37 (Android 17 compatibility-mode
  behaviour applies) — forced by the Compose BOM 2026.08 line, whose
  artifacts require compileSdk 37 and whose `OldTargetApi` lint check the
  build treats as an error. Alongside: Gradle 8.14 → 9.7, AGP 8.10 → 9.3
  (built-in Kotlin support, so the standalone `org.jetbrains.kotlin.android`
  plugin is gone), Kotlin 2.1 → 2.4, KSP 2.3, ktlint plugin 14, JUnit 6,
  Room 2.8, ktor 3.5, coroutines 1.11, kotlinx-serialization 1.11, Amplify
  2.39, coil 3.5, and gradle-play-publisher 4.1. `material-icons-core` is now
  an explicit dependency (material3 no longer pulls it in transitively).
  Supersedes the dependabot group PR #1147, which could not build as-is.
