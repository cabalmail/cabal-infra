# Cabalmail Android Client

Native Android client (phone + tablet, single codebase) for Cabalmail. Kotlin,
Jetpack Compose, Material 3. Speaks only to the Lambda API surface — no IMAP
or SMTP transport in the client. See
[`docs/1.x/android-client-plan.md`](../docs/1.x/android-client-plan.md) for the
full plan and phase breakdown.

## Modules

| Module | Type | Purpose |
|---|---|---|
| `app` | `com.android.application` | Compose UI, navigation, view models |
| `kit` | `com.android.library` | Auth, API client, models, caching, MIME, runtime config — no UI dependencies. Sibling of the Apple `CabalmailKit` package (contract-compatible, no shared code) |

## Requirements

- JDK 17+ (CI uses Temurin 21)
- Android SDK (`local.properties` with `sdk.dir`, or `ANDROID_HOME`); Gradle
  fetches missing SDK components itself
- Min SDK 31 (Android 12), compile/target SDK 36

## Build and test

```sh
./gradlew assembleDebug        # debug APK
./gradlew :kit:test            # kit unit tests (JUnit 5)
./gradlew :app:testDebugUnitTest
./gradlew ktlintCheck          # lint (ktlintFormat to auto-fix)
```

## App icon

`app/src/main/ic_launcher-playstore.png` (the 512×512 Google Play listing
icon) is **generated** from the repo-wide brand vector by `make logo` at the
repo root — never edit it by hand; see [`vector/README.md`](../vector/README.md).
It sits beside `res/` so it is uploaded to the Play Console but not packaged
into the APK. The in-app launcher icon is the adaptive icon under
`res/mipmap-anydpi/`.

## Runtime configuration

The only build-time value is the control domain; everything else (API URL,
Cognito pool, mail domains) is fetched from
`https://{CONTROL_DOMAIN}/config.json` at runtime and cached. The checked-in
default is a placeholder — point a local build at a live environment with a
user-level Gradle property (never committed):

```sh
# ~/.gradle/gradle.properties
cabalmail.controlDomain=admin.your-control-domain.example
```

or `./gradlew assembleDebug -Pcabalmail.controlDomain=...`.
