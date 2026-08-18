# App R8 rules (plan §7.6). Release builds shrink, optimize, and obfuscate
# with R8 full mode (AGP 8 default). Everything below is a rule the
# libraries do not ship as consumer rules themselves.

# kotlinx.serialization: keep the generated serializers reachable from the
# @Serializable classes' companions (the documented full-mode rules).
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.AnnotationsKt
-keepclassmembers class kotlinx.serialization.json.** { *** Companion; }
-keepclasseswithmembers class kotlinx.serialization.json.** { kotlinx.serialization.KSerializer serializer(...); }
-keep,includedescriptorclasses class com.cabalmail.**$$serializer { *; }
-keepclassmembers class com.cabalmail.** { *** Companion; }
-keepclasseswithmembers class com.cabalmail.** { kotlinx.serialization.KSerializer serializer(...); }

# Ktor / OkHttp: reflection-free on our code paths; keep the engine's
# service loader entries the ServiceLoader lookup needs.
-keep class io.ktor.client.engine.okhttp.OkHttpEngineContainer { *; }
-keepnames class io.ktor.client.HttpClientEngineContainer
-dontwarn org.slf4j.**
-dontwarn io.ktor.**

# Coil 3 registers its network fetcher through ServiceLoader.
-keep class coil3.network.okhttp.internal.OkHttpNetworkFetcherServiceLoaderTarget { *; }
-keepnames class coil3.util.FetcherServiceLoaderTarget

# JetBrains markdown parser: no reflection, nothing to keep.

# WorkManager: workers are looked up by class name.
-keep class com.cabalmail.android.notifications.NewMailSync$NewMailWorker { *; }

# security-crypto pulls Tink, which references errorprone's compile-time
# annotations without shipping them; they are never needed at runtime.
-dontwarn com.google.errorprone.annotations.**

# DataStore (preferences) serializes through protobuf-javalite, which finds
# message fields reflectively by name; full-mode R8 renames them otherwise
# ("Field preferences_ ... not found" at first read).
-keepclassmembers class * extends com.google.protobuf.GeneratedMessageLite { <fields>; }
-keepclassmembers class * extends androidx.datastore.preferences.protobuf.GeneratedMessageLite { <fields>; }
