# Native Android Client Plan

## Context

The React admin app (`react/admin/`) and native Apple clients (`apple/`) currently serve as the Cabalmail clients. Version 1.1.0 introduces a native Android client that mirrors the *user-facing* portions of the Apple client (mail reading/compose/send, folder management, address creation and revocation, on-the-fly `From` addresses) without sharing code with either existing client.

Administrative functionality (user management, DMARC reports, multi-user address assignment) is out of scope. Admins will continue to use the web app for those workflows.

The Apple client has evolved substantially since this plan was first drafted (it was written against the 0.1.x-era feature set). Functional parity now includes several capabilities that shipped in the intervening releases and are reflected throughout the phases below:

- **Cross-folder structured search** (`/search_envelopes`) as a first-class scope, not a query parameter — with a filter sheet and All / Unread / Flagged pills.
- **Configurable sort** (received date, sent date, sender, subject) and **sliding-window virtualization** for large mailboxes.
- **Bulk multi-select** for batch move / flag / read / dispose.
- **Threading identity** on every envelope (`message_id` / `in_reply_to` / `references`), consumed for correct reply threading (the list itself stays flat — no conversation grouping in either client).
- **Cross-device draft sync** via `/save_draft` (the plan's original "local-only drafts" is superseded).
- **Resume cursor** via `/get_nav_state` / `/set_nav_state` — remember and offer to restore the last folder/message.
- **Server-synced preferences** via `/get_preferences` / `/set_preferences` — the From display name plus theme / accent / density, shared with the web app.
- **Address favorites** (`/set_favorite`) and **permanent delete / empty trash** (`/purge_messages`, `/empty_trash`).

Scope of "Android client" for 1.1.0:
- **Android phone** and **tablet** (single codebase with adaptive layouts via Compose `WindowSizeClass`)
- **ChromeOS** compatibility comes for free via the phone/tablet target
- **Foldables** handled automatically by Compose's adaptive layout primitives

Wear OS, Android TV, and Android Auto are explicitly out of scope.

Play Store public release is explicitly *not* a 1.1.x goal -- the roadmap places that at 1.5.x. This phase produces a working client that is continuously built and tested in CI and distributable via Play Console internal testing tracks.

## Approach

Seven phases: project scaffolding and shared module; **CI/CD (early, so every subsequent phase runs through it)**; authentication and API transport; mail reading; mail composition including on-the-fly `From`; address and folder management; platform polish and adaptive layouts.

### Guiding principles

- **API-backed from day one.** The Apple client originally planned direct IMAP/SMTP transports but shipped with `ApiBackedImapClient` -- the hand-rolled IMAP stack proved unreliable across network transitions, sleep/wake, and provider quirks (Issue #371). The Android client skips that detour entirely and speaks only to the existing Lambda API surface (`/list_folders`, `/list_envelopes`, `/fetch_message`, `/set_flag`, `/move_messages`, `/send`, etc.). No IMAP library, no MIME transport layer, no IDLE plumbing.
- **Native idioms over parity.** Where the Apple client uses a SwiftUI control, the Android client uses the Material 3 equivalent: `NavigationBar`, `NavigationRail`, `ListItem`, `SearchBar`, `SwipeToDismissBox`, `DropdownMenu`, etc. The goal is an app that feels at home next to Gmail, not a translation of the iOS UI.
- **Jetpack Compose first.** Use Compose for all views. Drop to the View system only where Compose lacks a capability (e.g. `WebView` for HTML email rendering).
- **No new Lambdas required.** The existing API surface covers all operations the client needs.
- **No code sharing with Apple or web.** Kotlin types are defined fresh. Sharing is limited to the *contract* (endpoint paths and JSON shapes).
- **CI from day one.** The Android workflow lands in Phase 2 against the empty scaffold. Every subsequent phase is developed under green CI, not alongside it.

### Lessons from the Apple client

| iOS plan | What actually shipped | Android implication |
|---|---|---|
| Direct IMAP/SMTP as primary transport | `ApiBackedImapClient` via Lambda API | Start API-backed; no IMAP spike |
| MailCore2 vs swift-nio-imap spike | Neither -- API-backed | No library evaluation needed |
| IDLE for foreground push | Polling (no IDLE over API) | Poll-based refresh from the start |
| Amplify Swift for Cognito | Amplify Swift | Use Amplify Android |
| `APPEND` for sent/drafts | `/send` handles Outbox + Sent; `/save_draft` owns the Drafts lifecycle | Client-side APPEND still unneeded, but drafts sync server-side (see Phase 5) |
| MIME parsing for `fetchPart` | Fetch full body, parse MIME client-side | Same approach in Kotlin |
| Local-only drafts | Cross-device sync via `/save_draft`, Markdown-canonical bodies | Same -- Markdown-canonical compose, server draft sync |
| Flat list, no threading data | Envelopes carry `message_id`/`in_reply_to`/`references`; used for reply threading only | Same -- flat list, threading powers replies |
| Search as an afterthought | Cross-folder structured search (`/search_envelopes`) + filter sheet + All/Unread/Flagged pills | Build search as a first-class scope |
| No cross-device resume | Nav-state cursor (`/get_nav_state`/`/set_nav_state`) with restore prompt | Same -- resume cursor |
| Prefs stored locally | Display name + theme/accent/density synced via `/get_preferences`/`/set_preferences` | Sync the shared prefs server-side (see Phase 6) |

> **Erratum (2026-08-07):** The "Amplify Swift" row is wrong: Amplify did not ship on
> Apple either. The Apple client's auth is a hand-rolled Cognito
> `USER_PASSWORD_AUTH` JSON client (`CabalmailKit/Auth/AuthService.swift`);
> Amplify Android should be weighed on its own merits, not as a mirror of
> the Apple choice.

### Stack decisions

| Choice | Decision | Rationale |
|---|---|---|
| Language | **Kotlin** only | Standard; no Java in new code |
| UI | **Jetpack Compose + Material 3** | SwiftUI analog; Google-recommended |
| Min SDK | **API 31 (Android 12)** | Future-proofing over reach; cleaner Compose ergonomics, built-in Splash Screen API, Material You dynamic color without compat shims |
| Target SDK | **Latest stable (API 35 / Android 15)** | Play Store requires recent target SDK |
| Build | **Gradle + Kotlin DSL** with version catalog (`libs.versions.toml`) | Current convention |
| Architecture | **ViewModels + StateFlow + Repository** (Compose-friendly MVVM) | Idiomatic; testable |
| HTTP | **Ktor client** | Pure Kotlin, multiplatform-ready if KMP ever materializes |
| Auth | **AWS Amplify Android** (`amplify-auth-cognito`) | Mirrors Apple; same SRP flow; proven against the existing Cognito pool |
| Persistence | **DataStore** (preferences) + **Room** (envelope/body cache, if needed) | Modern Jetpack stack |
| Image loading | **Coil** | Compose-native, Kotlin-first |
| HTML rendering | **WebView** with hardened settings | Same model as iOS WKWebView |
| DI | **Manual constructor injection** to start | Don't over-architect early; reach for Hilt only if wiring becomes painful |
| Testing | **JUnit5 + Turbine** (Flow testing) + **Compose UI tests** | Standard |
| Linting | **ktlint + Android Lint** | Mirrors swiftlint role from apple.yml |

### Repository layout

A new top-level directory, sibling to `apple/` and `react/admin`:

```
android/
  settings.gradle.kts
  build.gradle.kts                     # root build file
  gradle.properties
  gradle/
    libs.versions.toml                 # version catalog
    wrapper/
  app/                                 # phone + tablet app module
    build.gradle.kts
    src/
      main/
        kotlin/com/cabalmail/android/
          CabalmailApp.kt              # Application class (Amplify init)
          MainActivity.kt
          ui/
            mail/                      # folder list, message list, detail
            compose/                   # email composition
            addresses/                 # address management
            folders/                   # folder management
            settings/                  # preferences
            auth/                      # login, signup, forgot password
            theme/                     # Material 3 theme, dynamic color
          navigation/                  # NavHost, route definitions
        res/
        AndroidManifest.xml
      test/                            # unit tests
      androidTest/                     # instrumented/UI tests
  kit/                                 # shared library module
    build.gradle.kts
    src/
      main/kotlin/com/cabalmail/kit/
        auth/                          # Amplify Cognito wrapper
        api/                           # ApiClient (Ktor), endpoint definitions
        models/                        # Envelope, Message, Address, Folder, etc.
        cache/                         # Envelope + body disk cache
        mime/                          # Client-side MIME parsing
        config/                        # Runtime config fetch + cache
      test/kotlin/                     # unit tests
  README.md
```

`kit/` is the spiritual sibling of `CabalmailKit/`. The split lets future targets (Wear, benchmark module) consume it without dragging UI dependencies.

---

## Phase 1: Project Scaffolding & Shared Module

### 1. Gradle project

Create `android/` containing:
- Root `build.gradle.kts` applying the Android Gradle Plugin and Kotlin plugin at the top level (no `allprojects` anti-pattern -- use convention plugins or `subprojects` minimally).
- `settings.gradle.kts` including `app` and `kit` modules, with `pluginManagement` and `dependencyResolutionManagement` blocks.
- `gradle/libs.versions.toml` version catalog declaring all dependencies (Compose BOM, Ktor, Amplify, Coil, Room, DataStore, JUnit5, Turbine, ktlint).
- `app/` module: `com.android.application`, min SDK 31, target SDK 35, Compose enabled, Material 3 theme with dynamic color.
- `kit/` module: `com.android.library`, same SDK constraints, no Compose dependency (pure Kotlin + Android framework).

### 2. Runtime configuration

The Apple client fetches `https://{control_domain}/config.json` at first launch (added in the iOS work as a JSON sibling to the React app's `config.js`). The Android client uses the same endpoint.

`kit/src/main/kotlin/com/cabalmail/kit/config/ConfigService.kt`:
- Fetches `config.json` on first launch via Ktor.
- Caches to `DataStore` (encrypted via `EncryptedSharedPreferences` if the config contains anything sensitive; plain `DataStore` otherwise since the config values are also served publicly).
- Exposes `apiUrl`, `host`, `cognitoUserPoolId`, `cognitoClientId`, `mailDomains` as a `StateFlow<Config?>`.

The control domain itself is the one value that must be baked in at build time. Store it in `app/build.gradle.kts` as a `buildConfigField`:

> **Erratum (2026-08-18):** Retired. Baking the domain in meant one build per environment and left the Play Console upload — which sets no property — pointed at the placeholder, unable to sign in anywhere. The client now asks for the control domain on the sign-in screen and remembers it per install (with the cached `config.json`), the same as the Apple client; `BuildConfig.CONTROL_DOMAIN` survives only as an optional developer prefill (empty by default) and no build-type or flavor variants exist.

```kotlin
buildConfigField("String", "CONTROL_DOMAIN", "\"admin.example.com\"")
```

Different values per build type (debug/release) or product flavor (dev/stage/prod) if needed.

### 3. `kit/` module -- scaffolding

- Folders: `auth/`, `api/`, `models/`, `cache/`, `mime/`, `config/`.
- Placeholder `CabalmailClient` class that will own the auth session and expose the API surface to the app layer.
- Unit test with a single smoke test verifying the module compiles.

### 4. App shell

- `MainActivity.kt` with a Compose `setContent` block.
- Material 3 theme with `dynamicColorScheme()` (API 31 guarantees this works).
- Splash screen via the platform Splash Screen API (no library -- API 31 built-in).
- Placeholder "Hello, Cabalmail" screen.

### Phase 1 verification

1. `cd android && ./gradlew assembleDebug` succeeds.
2. `cd android && ./gradlew :kit:test` succeeds.
3. Empty app launches in the Android Emulator (Pixel 8, API 35) and shows "Hello, Cabalmail" with dynamic color theming.

---

## Phase 2: CI/CD

Land the Android workflow against the Phase 1 scaffold so every subsequent phase develops under green CI. Unlike `apple.yml` which requires macOS runners, Android CI runs on `ubuntu-latest` -- faster, cheaper (free for public repos), and no macOS minute multiplier.

### 1. Workflow layout

**`.github/workflows/android.yml`** -- triggers on `android/**` path changes, pushes to `main`/`stage`, and manual `workflow_dispatch`. Three jobs:

| Job | Runner | Purpose |
|---|---|---|
| `test` | `ubuntu-latest` | `./gradlew :kit:test :app:testDebugUnitTest`, ktlint, Android Lint |
| `build` | `ubuntu-latest` | `./gradlew assembleRelease` (unsigned -- verifies compilation) |
| `upload` | `ubuntu-latest` | Sign APK/AAB, upload to Play Console internal track (runs on `main`/`stage` only, skipped on PRs) |

Environment mapping follows the existing repo convention: `main` -> prod, `stage` -> stage. Other branches build and test only.

### 2. Toolchain pinning

- JDK via `actions/setup-java@v4` with `distribution: temurin` and an explicit `java-version` (e.g. `21`).
- Android SDK via Gradle's built-in SDK download (the `ubuntu-latest` runner has `ANDROID_HOME` set; Gradle auto-fetches missing SDK components via `sdkmanager`).
- `actions/cache@v5` for `~/.gradle/caches` and `~/.gradle/wrapper`, keyed on hashes of `gradle/libs.versions.toml`, `gradle/wrapper/gradle-wrapper.properties`, and `*.gradle.kts` files.

### 3. Linting

- **ktlint** via the `ktlint-gradle` plugin, run in the `test` job. Mirrors `swiftlint` from `apple.yml`.
- **Android Lint** via `./gradlew lint`. Warnings promoted to errors for release builds (`lintOptions { warningsAsErrors = true }`).

### 4. App signing

Android signing is simpler than Apple signing -- no provisioning profiles, no certificate import ceremony.

- **Upload keystore**: generate a `.jks` locally (`keytool -genkeypair`), base64-encode, store as `ANDROID_KEYSTORE_BASE64` secret. At job start, decode to a temp file.
- **Keystore password**, **key alias**, **key password**: separate secrets (`ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`).
- The signed AAB is the upload artifact. Play App Signing re-signs with Google's distribution key, so the upload key is the only secret CI needs.

Signing block in the workflow:

```yaml
- name: Decode keystore
  run: echo "${{ secrets.ANDROID_KEYSTORE_BASE64 }}" | base64 -d > "$RUNNER_TEMP/upload.jks"

- name: Build signed AAB
  working-directory: android
  env:
    KEYSTORE_PATH: ${{ runner.temp }}/upload.jks
    KEYSTORE_PASSWORD: ${{ secrets.ANDROID_KEYSTORE_PASSWORD }}
    KEY_ALIAS: ${{ secrets.ANDROID_KEY_ALIAS }}
    KEY_PASSWORD: ${{ secrets.ANDROID_KEY_PASSWORD }}
  run: ./gradlew bundleRelease
```

With matching `signingConfigs` in `app/build.gradle.kts` reading from environment variables.

### 5. Play Console upload

- **`gradle-play-publisher`** (Triple-T) Gradle plugin: `./gradlew publishBundle --track internal`. Requires a Google Play service account JSON key stored as `PLAY_SERVICE_ACCOUNT_JSON` secret.
- Marketing version derived from `CHANGELOG.md` (same `sed` pattern as `apple.yml`).
- Version code: `github.run_number` (monotonically increasing integer, which is all Play Console requires).

### 6. Workflow skeleton

```yaml
name: Build and Deploy Android Client

permissions:
  contents: read

on:
  workflow_dispatch:
  push:
    branches: [main, stage]
    paths:
      - 'android/**'
      - '.github/workflows/android.yml'

jobs:
  test:
    name: Test
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - uses: actions/setup-java@v4
        with: { distribution: temurin, java-version: '21' }
      - uses: actions/cache@v5
        with:
          path: |
            ~/.gradle/caches
            ~/.gradle/wrapper
          key: gradle-${{ runner.os }}-${{ hashFiles('android/**/*.gradle.kts', 'android/gradle/libs.versions.toml') }}
          restore-keys: gradle-${{ runner.os }}-
      - name: Run tests and lint
        working-directory: android
        run: ./gradlew :kit:test :app:testDebugUnitTest ktlintCheck lint

  build:
    name: Build release
    needs: test
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - uses: actions/setup-java@v4
        with: { distribution: temurin, java-version: '21' }
      - uses: actions/cache@v5
        with:
          path: |
            ~/.gradle/caches
            ~/.gradle/wrapper
          key: gradle-${{ runner.os }}-${{ hashFiles('android/**/*.gradle.kts', 'android/gradle/libs.versions.toml') }}
          restore-keys: gradle-${{ runner.os }}-
      - name: Assemble release (unsigned)
        working-directory: android
        run: ./gradlew assembleRelease

  upload:
    name: Upload to Play Console
    needs: [test, build]
    if: github.event_name != 'pull_request' && (github.ref_name == 'main' || github.ref_name == 'stage')
    runs-on: ubuntu-latest
    environment: ${{ github.ref_name == 'main' && 'prod' || 'stage' }}
    steps:
      - uses: actions/checkout@v5
      - uses: actions/setup-java@v4
        with: { distribution: temurin, java-version: '21' }
      - name: Decode keystore
        run: echo "${{ secrets.ANDROID_KEYSTORE_BASE64 }}" | base64 -d > "$RUNNER_TEMP/upload.jks"
      - name: Publish to internal track
        working-directory: android
        env:
          KEYSTORE_PATH: ${{ runner.temp }}/upload.jks
          KEYSTORE_PASSWORD: ${{ secrets.ANDROID_KEYSTORE_PASSWORD }}
          KEY_ALIAS: ${{ secrets.ANDROID_KEY_ALIAS }}
          KEY_PASSWORD: ${{ secrets.ANDROID_KEY_PASSWORD }}
          PLAY_SERVICE_ACCOUNT_JSON: ${{ secrets.PLAY_SERVICE_ACCOUNT_JSON }}
        run: ./gradlew bundleRelease publishBundle --track internal
```

### Phase 2 verification

1. Open a PR touching `android/**`; confirm `test` and `build` run and pass against the Phase 1 scaffold.
2. Confirm the workflow does **not** run when only `react/**`, `apple/**`, or `terraform/**` change.
3. Confirm Gradle cache hits on a second run reduce build wall-clock noticeably.
4. Merge to `stage`; confirm a signed AAB uploads to the Play Console internal testing track.

---

## Phase 3: Authentication & API Client

A single transport layer -- the Lambda API surface -- unified under `CabalmailClient` in `kit/`.

### 1. Cognito authentication

The Apple client uses Amplify Swift. The Android analog is **Amplify Android** (`aws-amplify/amplify-android`), which wraps the same SRP flow and handles token refresh.

> **Erratum (2026-08-07):** The Apple client does not use Amplify (or SRP); it
> hand-rolls Cognito `USER_PASSWORD_AUTH` in `AuthService.swift`. "Mirrors
> Apple" would mean a small hand-rolled JSON client, as the Linux plan later
> specified.

`kit/src/main/kotlin/com/cabalmail/kit/auth/AuthService.kt`:
- `signIn(username, password)`, `signUp(username, password, email, phone)`, `confirmSignUp(username, code)`
- `forgotPassword(username)` / `confirmForgotPassword(username, code, newPassword)`
- `signOut()`
- `suspend fun currentIdToken(): String` -- fresh JWT for API calls; refreshes if within 5 minutes of expiry
- Tokens stored by Amplify in `EncryptedSharedPreferences` (Android Keystore-backed) automatically

Amplify initialization happens in `CabalmailApp.kt` (`Application.onCreate`), configured programmatically from the `config.json` values (no `amplifyconfiguration.json` file -- the config is fetched at runtime).

### 2. API client

`kit/src/main/kotlin/com/cabalmail/kit/api/ApiClient.kt` -- a class wrapping Ktor `HttpClient`.

All requests attach `Authorization: <idToken>` via a Ktor `HttpRequestInterceptor` that calls `authService.currentIdToken()`. 401 responses trigger a single retry after a forced token refresh; a second 401 surfaces as `AuthError.SessionExpired`.

Endpoints (mirroring the Apple `ApiBackedImapClient` + `ApiClient`):

| Method | HTTP | Endpoint | Notes |
|---|---|---|---|
| `listFolders()` | GET | `/list_folders` | Returns folder tree |
| `folderStatus(folder)` | GET | `/folder_status` | STATUS: messages/unseen/uidvalidity/uidnext (+ optional flagged count) |
| `listEnvelopes(folder, sort, offset, limit)` | GET | `/list_envelopes` | Positional (offset/limit) envelope window, sorted; carries threading + auth-result fields |
| `searchEnvelopes(query, filters, cursor)` | GET | `/search_envelopes` | Structured search (single- or cross-folder), newest-first, opaque page cursor |
| `fetchMessage(folder, uid)` | GET | `/fetch_message` | Full RFC 822 body |
| `listAttachments(folder, uid)` | GET | `/list_attachments` | Attachment metadata |
| `fetchAttachment(folder, uid, part)` | GET | `/fetch_attachment` | Returns presigned S3 URL |
| `fetchInlineImage(folder, uid, part)` | GET | `/fetch_inline_image` | Inline image data |
| `setFlag(folder, uids, flag, value)` | POST | `/set_flag` | Set/clear one IMAP flag (`\Seen`, `\Flagged`, `\Answered`, `\Forwarded`) |
| `moveMessages(folder, uids, dest)` | POST | `/move_messages` | Move between folders |
| `purgeMessages(folder, uids)` | POST | `/purge_messages` | Permanent expunge -- **trash folders only** |
| `emptyTrash(folder)` | POST | `/empty_trash` | Expunge an entire trash folder |
| `send(message)` | POST | `/send` | Send; handles Outbox + Sent server-side; optional `discard_draft_*` |
| `saveDraft(message, op, replacesUid, replacesUidValidity)` | POST | `/save_draft` | Save/replace/discard a Drafts copy (UIDPLUS lifecycle) |
| `listAddresses()` | GET | `/list` | User's addresses (includes favorite flag) |
| `newAddress(subdomain, local, comment)` | POST | `/new` | Create address |
| `revokeAddress(address)` | DELETE | `/revoke` | Delete address |
| `setFavorite(address, favorite)` | POST | `/set_favorite` | Favorite/unfavorite an address (drives From-picker ordering) |
| `fetchBimi(domain)` | GET | `/fetch_bimi` | BIMI logo lookup |
| `getPreferences()` / `setPreferences(...)` | GET/PUT | `/get_preferences` `/set_preferences` | Server-synced prefs: `name`, `theme`, `accent`, `density` |
| `getNavState()` / `setNavState(cursor)` | GET/POST | `/get_nav_state` `/set_nav_state` | Cross-device resume cursor |
| `newFolder(name, parent)` | POST | `/new_folder` | Create folder |
| `deleteFolder(name)` | DELETE | `/delete_folder` | Delete folder (must be empty) |
| `subscribeFolder(name)` | POST | `/subscribe_folder` | Subscribe |
| `unsubscribeFolder(name)` | POST | `/unsubscribe_folder` | Unsubscribe |

> **Erratum (2026-08-07):** The HTTP column is wrong for most mutating rows: the
> deployed API uses PUT (`/set_flag`, `/move_messages`, `/send`,
> `/save_draft`, `/new_folder`, `/subscribe_folder`, `/unsubscribe_folder`,
> `/set_favorite`, `/set_nav_state`) and DELETE (`/revoke`, `/delete_folder`,
> `/purge_messages`, `/empty_trash`). See `react/admin/src/ApiClient.js` for
> the authoritative verbs.

`/append_sent` exists but is an internal SQS consumer that `/send` enqueues -- the client never calls it directly.

Ktor client configuration:
- `ContentNegotiation` with `kotlinx.serialization` for JSON
- `HttpTimeout` (30s connect, 60s request)
- `Logging` plugin at `LogLevel.HEADERS` for debug builds only
- `HttpResponseValidator` for structured error mapping

### 3. Models

`kit/src/main/kotlin/com/cabalmail/kit/models/` -- Kotlin data classes with `@Serializable`:

- `Config` -- runtime configuration from `config.json`
- `Folder` -- name, delimiter, attributes, unread count
- `Envelope` -- uid, from, to, cc, subject, date, flags, hasAttachments, size, **threading identity** (`messageId`, `inReplyTo`, `references` -- lists of angle-bracketed ids, `references` capped at the newest 20 server-side), **auth results** (SPF/DKIM/DMARC verdicts), and **priority** (from `X-Priority`/`Importance`). All additive/optional -- tolerate their absence on pre-rollout envelopes.
- `Message` -- envelope + raw body (RFC 822)
- `Address` -- address string, subdomain, local part, comment, domain, **favorite** flag
- `Attachment` -- filename, content type, size, part ID
- `BimiLogo` -- SVG URL or image data
- `Preferences` -- server-synced `name` / `theme` / `accent` / `density` (see Phase 6)
- `NavState` -- resume cursor: `folder`, `messageId`, `uid`, `uidValidity`, `listScroll`, `messageScroll`, `clientId` (stable per-install), `updatedAt` (server-stamped)
- `Draft` -- id, from, to/cc/bcc, subject, Markdown body, `inReplyTo`/`references`, compose intent, and server coordinates (`serverUid`/`serverUidValidity`)

Envelopes are the same wire shape across `/list_envelopes` and `/search_envelopes`, so a single decoder serves both. Threading fields ride the envelope but the message list stays a **flat list** -- no conversation grouping in either client. They exist so `ReplyBuilder` can construct a correct `References` chain (see Phase 5).

### 4. Caching

- **Envelope cache**: `Room` database keyed by `(folder, uid)`, backing the sliding window so a revisited folder paints from cache before the network refresh lands. LRU-bounded, not a full-folder mirror -- Cabalmail mailboxes can be very large, so the client caches the working window plus recent bands rather than syncing every envelope. A STATUS/UIDVALIDITY check invalidates the folder's cache on mismatch.
- **Message body cache**: disk cache in the app's internal storage, keyed by `(folder, uid)`, evicted LRU with a configurable cap (default 200 MB).
- **Address list**: in-memory `StateFlow` with invalidation on mutation.

### Phase 3 verification

1. Unit tests in `kit/` cover: Amplify auth happy path + refresh (mocked), API client token attachment and 401 retry (mocked Ktor engine), JSON deserialization for all model types. These run in `test` on every PR.
2. Manual: sign in on a dev build; confirm token stored in `EncryptedSharedPreferences`, `listAddresses()` returns expected data, `listEnvelopes("INBOX", 1)` returns expected messages.
3. Manual: force-expire the JWT; confirm API calls recover silently.
4. Manual: kill the app and relaunch; confirm session restores without re-authentication.

---

## Phase 4: Mail Reading

First user-visible feature: a functional read-only mail client.

### 1. Folder list

`app/.../ui/mail/FolderListScreen.kt` -- a Compose `LazyColumn` backed by `ApiClient.listFolders()`.

- INBOX pinned to the top, then user folders, then system folders (Sent, Drafts, Trash, Junk) grouped with section headers.
- Unread counts shown as trailing badges (from the folder status returned by the API).
- Pull-to-refresh via `PullToRefreshBox`.
- On phone: folders are the root screen. On tablet/foldable: folders occupy the leading pane of a `ListDetailPaneScaffold` or `NavigationSuiteScaffold`.

### 2. Message list

`app/.../ui/mail/MessageListScreen.kt` -- middle pane on tablet, or navigated-to screen on phone.

- **Windowed virtualization.** Backed by `ApiClient.listEnvelopes(folder, sort, offset, limit)` -- positional (offset/limit) paging, not page tokens. Hold a contiguous sliding window of envelopes keyed by list index, load the next/prior band as the user scrolls, and render placeholder rows for not-yet-loaded indices. This mirrors the Apple client's index-addressed virtualization and keeps large mailboxes responsive. `LazyColumn` with a scroll-position listener drives the window.
- Each row: sender (with BIMI avatar / colored-initials fallback via `fetchBimi`), subject, snippet, date, read/unread indicator (from `\Seen`), attachment icon, flag indicator (from `\Flagged`), a **priority badge** when the envelope is flagged important, and an **auth-result warning** icon when SPF/DKIM/DMARC did not pass.
- **Filter pills** (`FilterChip` row): All / Unread / Flagged, with counts sourced from `/folder_status` (unseen, flagged). Purely a display narrowing over the loaded window; resets to All on folder switch.
- **Sort** (overflow menu): Date Received (default) / Date Sent / From / Subject, ascending or descending -- passed to `/list_envelopes`.
- **Bulk multi-select.** A "Select" affordance turns rows into checkboxes and swaps the top bar for a contextual action bar (mark read/unread, flag, move, dispose, purge). Selection is keyed by UID so cross-folder search results route each operation to its true source folder. Selection clears after a move/dispose, persists after a flag toggle.
- Swipe actions via `SwipeToDismissBox`: swipe left -> `moveMessages` to Archive or Trash per the "Dispose action" setting (default: Archive); swipe right -> toggle flag / mark-read via `setFlag`.
- Long-press context menu mirrors swipe and bulk actions for accessibility and discoverability.
- Pull-to-refresh re-STATUSes the folder and reconciles the top of the window.

### 2a. Search

Search is a **first-class scope**, not a query parameter on the folder list -- matching the Apple client's `MessageListScope.search`.

- A `SearchBar` opens a cross-folder search backed by `ApiClient.searchEnvelopes(query, filters, cursor)` (`/search_envelopes`). With no folder it searches the user's subscribed folders (excluding Trash) and merges newest-first; each result carries its source folder so per-row operations route correctly.
- A **filter sheet** exposes the structured predicates the endpoint accepts: `from`, `to`, `subject`, `since`/`before` (day-granular), `unread`, `flagged`, `has_attachment`, and a "this folder only" toggle. No raw IMAP-SEARCH syntax crosses the wire.
- Results use the same row layout and the same opaque-cursor paging as the folder list.

### 3. Message detail

`app/.../ui/mail/MessageDetailScreen.kt` -- trailing pane on tablet, or navigated-to screen on phone.

- Headers: From (with BIMI logo via `ApiClient.fetchBimi`), To/Cc, date, subject. **Auth-result chips** (SPF/DKIM/DMARC pass/fail) and a **priority** indicator when present.
- Body: fetched via `ApiClient.fetchMessage(folder, uid)`. Messages are never auto-marked-as-read by default -- the user explicitly marks read via swipe, toolbar button, or context menu. An opt-in "mark read on open" setting is available (Phase 6) but defaults to off.
- **Render mode.** HTML bodies support two modes, matching the Apple client: **Original** (author styling) and **Reader** (system font, capped line length, dark-mode aware). The default follows the "Body render mode" preference (Phase 6); a per-message toolbar toggle overrides it for the open message.
- MIME parsed client-side. HTML bodies render in an Android `WebView` (`AndroidView` composable wrapper) with restrictive settings:
  - `settings.javaScriptEnabled = false`
  - Custom `WebViewClient` that intercepts all URL loads and blocks remote content by default
  - `WebSettings.setBlockNetworkLoads(true)` unless the user taps "Load remote content"
  - `setWebContentsDebuggingEnabled(false)` in release builds
- Plain-text bodies render in a `SelectionContainer { Text(...) }`.
- Inline images resolved by fetching via `ApiClient.fetchInlineImage` and injecting as `data:` URIs into the HTML before loading.
- Attachments shown in a horizontal `LazyRow` below the body; tap downloads via `ApiClient.fetchAttachment` (presigned URL) and opens with `ACTION_VIEW` intent or the system file viewer.
- Toolbar: reply / reply-all / forward, flag, mark read/unread, move, and dispose. In a **trash folder** the dispose action becomes **permanent delete** via `ApiClient.purgeMessages` (with confirmation); the folder list surfaces an **Empty Trash** action calling `ApiClient.emptyTrash`. Both are trash-scoped server-side.

### 4. Sanitization

No JavaScript execution. Remote content blocked by default via `WebSettings.setBlockNetworkLoads(true)`. A toolbar button ("Load remote content") toggles network loads for the current message only -- does not persist. This mirrors the Apple client's `WKWebView` approach.

### 5. Resume cursor

The Apple client persists a navigation cursor server-side and offers to restore it. The Android client does the same via `/get_nav_state` / `/set_nav_state`.

- On foreground/scroll settle, debounce-write the cursor (`folder`, `messageId`, `uid`/`uidValidity`, scroll positions, and a stable per-install `clientId`) via `setNavState`.
- On launch, read the cursor. If it originated on **this** install, silently restore folder + message. If it came from a **different** device (different `clientId`, newer `updatedAt`), land in INBOX first and surface an opt-in "pick up where you left off" prompt rather than yanking the user elsewhere.
- The `clientId` is a UUID stored in `DataStore` (not backed up / not synced) so each install is distinguishable.

### Phase 4 verification

1. Manual on phone emulator (Pixel 8, API 35): sign in, browse folders, read a message with attachments, download an attachment.
2. Manual on tablet emulator (Pixel Tablet, API 35): confirm adaptive layout renders folder list + message list side by side, detail opens in trailing pane.
3. Manual: open a message containing remote tracking pixels; confirm no network request fires until "Load remote content" is tapped.
4. Manual: pull-to-refresh on the message list; confirm new messages appear.
5. Manual: scroll a large folder (thousands of messages); confirm placeholder rows fill in as bands load and memory stays flat.
6. Manual: toggle the All / Unread / Flagged pills and change sort; confirm the list and counts respond.
7. Manual: run a cross-folder search with a filter (e.g. `has_attachment` + `unread`); confirm results span folders and per-row dispose routes to the correct source folder.
8. Manual: multi-select several messages and bulk-move; confirm all move and selection clears.
9. Manual: on this device, open a message and background the app; on a second device (or the web app), confirm the resume prompt offers that position on next launch. In a trash folder, permanently delete a message and confirm Empty Trash clears it.

---

## Phase 5: Mail Composition & On-the-Fly `From`

The feature that differentiates Cabalmail from a generic mail client.

### 1. Compose screen

`app/.../ui/compose/ComposeScreen.kt` -- presented as a full-screen activity on phone, or a dialog/new window on tablet.

Fields:
- **From** -- an `ExposedDropdownMenuBox` seeded with `listAddresses()`, **no preselection by default**. The Send button is disabled until the user selects or creates an address. If the user has set a default From address in Settings, that address is preselected instead. The menu ends with a "**Create new address...**" item that opens a bottom sheet (subdomain picker + local-part field + comment) and calls `newAddress`; on success, the new address is selected.
- **To**, **Cc**, **Bcc** -- chip-based input fields. Contact autocomplete from the system `ContactsContract` provider (with runtime permission) and/or a learned frequency list in Room.
- **Subject** -- plain `TextField`.
- **Body -- Markdown-canonical.** Both first-party Apple composers persist the body as **Markdown** and emit the Markdown source as the message's text part, which is what makes cross-device draft sync lossless. The Android composer must do the same: whatever the editor surface (a formatting toolbar over an `AnnotatedString` buffer, or a minimal rich editor), the canonical form is Markdown and the wire body is the Markdown source. This keeps a draft saved on Android round-trippable on Apple/web and vice versa. The toolbar also carries an "Attach" button using the Photo Picker (`PickVisualMedia` on API 33+, `ACTION_OPEN_DOCUMENT` fallback on 31-32) and the document picker (`OpenDocument`).
- The **From display name** on outgoing mail comes from the server-synced `name` preference (`/get_preferences`), so the header matches across web/Apple/Android.
- **Send** builds the message and submits via `ApiClient.send()`. The `/send` endpoint handles Outbox + Sent server-side (no client-side APPEND) and, when sending from a synced draft, expunges the server draft copy via `discard_draft_uid`. While sending, the compose screen shows a progress indicator; on success it dismisses; on failure it remains open with a `Snackbar` error.

### 2. Reply / Reply All / Forward

Triggered from the message detail toolbar. The compose screen opens pre-populated:
- **From** defaults to the owned address that matches a recipient of the original, searched To -> Cc -> Bcc (matching the Apple `ReplyBuilder`). Revoked/unknown addresses fall back to no selection.
- **To** / **Cc** populated per reply semantics, with reply-all deduplication.
- **Subject** prefixed with `Re:` or `Fwd:` if not already (idempotent -- no `Re: Re:`).
- **Threading.** Reply and reply-all set `In-Reply-To` to the original's Message-ID and build a `References` chain from the original's `references` (preferring the real chain, falling back to `[In-Reply-To, Message-ID]` for pre-rollout envelopes). Because an open message overlays headers parsed from the fetched body onto the envelope, replies thread correctly even off a cached envelope that predates the threading rollout. **Forward deliberately breaks the thread** (emits no threading headers).
- **Body** quotes the original with an attribution line.

### 3. Drafts -- local buffer + cross-device sync

Cross-device draft sync **shipped for the Apple clients** via the `/save_draft` endpoint (see [`docs/draft-sync-and-threading.md`](../draft-sync-and-threading.md)); the original "local-only, deferred" plan is superseded. The Android client mirrors that model:

- **Local buffer.** Each in-progress draft persists to local storage (Room or a per-draft JSON file), autosaved atomically on a short debounce (~5s). This is the live editing buffer and the crash-recovery story; it survives process death.
- **Server sync.** Server saves go to the top-level `Drafts` mailbox via `/save_draft` and happen (a) on compose **close-without-send** (always) and (b) on a **60-second debounce** while composing -- skipped while the body is empty, while a send is running, or while another server save is in flight. Do not shorten the 60s floor: server saves are interactive IMAP writes against the single-task IMAP tier and the debounce bounds Lambda/EFS churn.
- **Last-writer-wins, loss-free.** Each save records the returned `(uidvalidity, uid)` and passes them as `replaces_uid` / `replaces_uidvalidity` on the next save (and as `discard_draft_uid` on send). The endpoint appends the new copy *before* expunging the old and guards the expunge on matching UIDVALIDITY, so the worst-case failure is a duplicate draft, never a lost one.
- **Resume / Edit Draft.** Opening a message in the `Drafts` folder offers **Edit Draft**, which seeds compose from the already-fetched message: recipients and subject from the envelope, Bcc and threading from the headers, and the body from the `text/plain` (Markdown) part -- lossless for first-party drafts precisely because compose is Markdown-canonical. An HTML-only foreign draft falls back to editing its HTML through the Markdown buffer.
- **Discard** removes both the local buffer and the server copy (`op: discard`).

### 4. Share target

Register the app as a share target (`<intent-filter>` with `ACTION_SEND` / `ACTION_SEND_MULTIPLE`) so users can share text, images, and files from other apps directly into the compose screen. The shared content populates the body and/or attachments.

### Phase 5 verification

1. Manual: compose and send to a personal address, confirm delivery and correct `From`.
2. Manual: in compose, open the From picker, create a new address, confirm it becomes the selected From and appears in the Addresses screen.
3. Manual: reply to a message, confirm From defaults to the addressee of the original.
4. Manual: kill the app mid-compose, relaunch, confirm draft restored from the local buffer.
5. Manual: share an image from the Photos app into Cabalmail; confirm it appears as an attachment in compose.
6. Manual: start a draft, wait for the 60s server save (or close without sending), then open the `Drafts` folder on a second device / the web app; confirm the draft appears and **Edit Draft** re-opens it with recipients, subject, body, and threading intact.
7. Manual: reply within a thread; inspect the sent message's `In-Reply-To` / `References` headers and confirm they chain correctly. Forward the same message; confirm it starts a new thread (no threading headers).

---

## Phase 6: Address & Folder Management + Settings

Non-mail features, given their own destinations in the navigation graph.

### 1. Addresses screen

`app/.../ui/addresses/AddressesScreen.kt` -- mirrors the Apple Addresses tab:
- Section "My Addresses": `ApiClient.listAddresses()`, with swipe-to-delete and long-press context menu calling `ApiClient.revokeAddress` (with confirmation dialog).
- **Favorites.** A star toggle calls `ApiClient.setFavorite(address, favorite)`. Favorited addresses sort to the top of the list and to the top of the Compose **From** picker, so frequently-used identities are one tap away.
- Section "Request New": bottom sheet with subdomain picker (`ExposedDropdownMenuBox`), local-part field, comment field, and "Create" button calling `ApiClient.newAddress`. Same validation rules as the web and Apple apps.
- Pull-to-refresh.

### 2. Folders screen

`app/.../ui/folders/FoldersAdminScreen.kt` -- mirrors the Apple Folders tab:
- Full folder list from `ApiClient.listFolders()`; subscribed/unsubscribed state shown.
- Subscribed folders get an unsubscribe action; unsubscribed folders get a subscribe action.
- "New Folder" FAB opening a dialog with name field and parent-folder picker.
- Delete action on empty user folders with confirmation dialog.

### 3. Settings

`app/.../ui/settings/SettingsScreen.kt` -- a dedicated navigation destination.

**Two storage tiers.** A subset of preferences is **synced server-side** via `/get_preferences` / `/set_preferences` so they stay consistent across web, Apple, and Android: the From **display name**, **theme**, **accent**, and **density**. Everything else is Android-local behavior stored in Jetpack `DataStore<Preferences>`. (The Apple client syncs `name` via the server and the rest via iCloud; Android has no iCloud, so routing the shared visual prefs through the server endpoint is both the portable choice and the one that matches the web app.)

> **Erratum (2026-08-07):** iCloud is not used. Since 0.11.x the Apple client syncs
> its whole settings set through `set_preferences`' per-user `app` map (see
> `APP_ALLOWED`), and the earlier `NSUbiquitousKeyValueStore` mirroring was
> removed. The storage-tier split here understates the server-synced set.

**Account:**
- Signed-in account display, sign-out button.
- **Display name** (synced) -- free-text, used as the From header's display name at send time. Empty = no display name.

**Reading:**

| Preference | Options | Default | Storage | Notes |
|---|---|---|---|---|
| Mark as read | Manual / On open / After delay (2s) | **Manual** | local | Manual = never set `\Seen` automatically. Matches the Apple client default. |
| Load remote content | Off / Ask / Always | **Off** | local | Controls whether `WebView` fetches remote resources. |
| Body render mode | Original / Reader | **Original** | local | Default for HTML bodies; per-message toggle in the reader overrides it. |
| Folder count display | Unread / Total / Both | **Unread** | local | What the badge on each folder shows. |
| Default sort | Received / Sent / From / Subject (+ asc/desc) | **Received, desc** | local | Message-list sort order. |

**Composing:**

| Preference | Options | Default | Storage | Notes |
|---|---|---|---|---|
| Default From address | None / (list of addresses) | **None** | local | None = From picker starts empty; Send blocked until user picks. When set, preselects in new-compose (replies still default to original addressee). |
| Signature | Text field | *(empty)* | local | Plain text, appended at compose time. |

**Actions:**

| Preference | Options | Default | Storage | Notes |
|---|---|---|---|---|
| Dispose action | Archive / Trash | **Archive** | local | Controls swipe-left and toolbar dispose throughout the app. |

**Appearance:**

| Preference | Options | Default | Storage | Notes |
|---|---|---|---|---|
| Theme | System / Light / Dark | **System** | synced* | `light`/`dark` sync to the server; System is an Android-local choice that defers to `isSystemInDarkTheme()`. |
| Accent | ink / oxblood / forest / azure / amber / plum | **forest** | synced | The shared palette used by web and Apple; seeds the Material 3 color scheme when dynamic color is off. |
| Density | Compact / Normal / Roomy | **Compact** | synced | List/row density. |
| Dynamic color | On / Off | **On** | local | Material You dynamic color from wallpaper (API 31+). An Android-native extra; when on, it takes precedence over the Accent seed. |

**About:**
- Version, build number, link to GitHub issues.

### Phase 6 verification

1. Manual: create, then revoke an address; confirm it disappears from the From picker in Compose.
2. Manual: create a nested folder, subscribe/unsubscribe, delete; confirm changes reflect in the folder list.
3. Manual: change signature, compose a new message, confirm signature appended.
4. Manual: open a message; confirm it stays unread (default: manual). Change setting to "On open"; open a message; confirm `\Seen` is set.
5. Manual: set Default From to an address; open a new compose; confirm preselected. Clear the setting; confirm From picker is empty and Send is disabled.
6. Manual: toggle theme to Dark; confirm immediate switch. Toggle Dynamic color off; confirm Material 3 falls back to the selected **Accent** seed. Change **Density**; confirm row spacing responds.
7. Manual: change theme/accent/density on Android, then open the web app; confirm the same values apply (server-synced). Set a **Display name** and send a message; confirm the From header carries it.
8. Manual: favorite an address; confirm it sorts to the top of both the Addresses list and the Compose From picker.

---

## Phase 7: Platform Polish

Cross-cutting work to make each form factor feel native, plus robustness improvements.

### 1. Phone

- `NavigationBar` (bottom) with Mail / Addresses / Folders / Settings destinations.
- Swipe actions tuned: left = dispose, right = flag/mark-read (Material 3 `SwipeToDismissBox`).
- Predictive back gesture support (opt in via `android:enableOnBackInvokedCallback="true"`).
- Edge-to-edge display with proper `WindowInsets` handling.
- Dynamic Type analog: respect system font size via `sp` units throughout.

### 2. Tablet / foldable

- `NavigationRail` (side) replaces bottom `NavigationBar` when `windowSizeClass.widthSizeClass >= WindowWidthSizeClass.Medium`.
- `ListDetailPaneScaffold` for the mail flow (folder list | message list | detail) with adaptive column widths.
- Keyboard shortcuts via `onKeyEvent` for hardware keyboards, mirroring the Apple client's set (Ctrl in place of Cmd): Ctrl+N compose, Ctrl+R reply, Ctrl+Shift+R reply all, Ctrl+Shift+U toggle read/unread, Ctrl+Shift+L toggle flag, and j/k row navigation.
- Foldable hinge-aware layout via `WindowInfoTracker` -- avoid placing content on the hinge.

### 3. Notifications

- Local notifications only (no FCM push -- same constraint as iOS without APNs).

  > **Erratum (2026-08-07):** iOS has had APNs push since 0.11.0. Android starting
  > with local notifications remains a choice (FCM not yet wired), not a
  > parity constraint.
- `WorkManager` periodic background sync (minimum 15 minutes): opens a short API session, fetches folder status, fires a local notification via `NotificationCompat` for new messages since last check. Notification channel: "New Mail" with default importance.
- Foreground polling when the app is visible: configurable interval (default 60 seconds) via `repeatOnLifecycle(Lifecycle.State.RESUMED)`.

### 4. Offline reading

- Room-cached envelopes and disk-cached message bodies from Phase 3 serve as the offline index.
- Offline banner shown when `ConnectivityManager.NetworkCallback` reports no connectivity.
- Queued compose messages persist in Room and send on reconnect.

### 5. Error handling

- Structured `CabalmailError` sealed class; user-facing messages mapped per subclass.
- `Snackbar` for transient errors, `AlertDialog` for blocking errors.
- No third-party crash reporting. Crashes are surfaced via Play Console's Android Vitals (automatic for Play-distributed builds).

### 6. Performance

- Baseline Profiles generated via `androidx.benchmark.macro` for faster cold start.
- R8 full mode for release builds (aggressive shrinking + obfuscation).
- Strict mode enabled in debug builds to catch disk/network on main thread.

### Phase 7 verification

1. Manual per form factor: run the golden path (sign in -> browse -> read -> reply -> send -> revoke address) on phone and tablet emulators.
2. Accessibility Scanner audit -- zero critical issues.
3. Airplane mode test: confirm cached messages remain readable; confirm queued sends fire on reconnect.
4. Rotate device mid-compose; confirm no state loss.
5. Split-screen / picture-in-picture: confirm the app handles configuration changes gracefully.

---

## Out of Scope for 1.1.0

- **Public Play Store release.** Tracked as 1.5.x. 1.1.x ships to Play Console internal testers only.
- **Push notifications (FCM).** Same blocker as iOS/APNs: needs a server-side IDLE watcher to bridge to FCM. Tracked alongside APNs work.

  > **Erratum (2026-08-07):** The blocker no longer exists: APNs push shipped in
  > 0.11.0 via a procmail delivery hook → SQS (`cabal-push-queue`) →
  > `push_dispatch`, with no IDLE watcher involved. FCM support is now an
  > extension of that shipped pipeline.
- **Kotlin Multiplatform code sharing with iOS.** The `CabalmailKit` Swift code stays Swift; `kit/` is a parallel Kotlin implementation. KMP is a future optimization, not a prerequisite.
- **Admin features** (user management, DMARC, multi-user address assignment). Admins continue to use the web app.
- **RSS reader.** Tracked as 2.x.
- **Wear OS / Android TV / Android Auto.** Out of scope for 1.1.0 and not on the current roadmap.

## Prerequisites

- **Google Play Console account** ($25 one-time registration fee), with the app record (`com.cabalmail.android`) registered and the Play Developer API enabled.
- **Service account** with Play Developer API access, JSON key stored as `PLAY_SERVICE_ACCOUNT_JSON` GitHub secret.
- **Upload keystore** generated locally (`keytool -genkeypair -v -keystore upload.jks -keyalg RSA -keysize 2048 -validity 10000`), base64-encoded and stored as `ANDROID_KEYSTORE_BASE64`. Play App Signing handles the distribution key.
- **Android Studio** installed locally for development and emulator management.

## Open Questions

1. **HTTP client: Ktor vs Retrofit/OkHttp.** Ktor is more Kotlin-idiomatic and keeps a KMP door open; Retrofit has a larger community and more sample code. Both work. Default: Ktor.
2. **Amplify Android vs hand-rolled Cognito SRP.** Amplify adds ~3-4 MB after R8 but provides token management, `EncryptedSharedPreferences` integration, and matches the iOS choice. Hand-rolling SRP saves size but costs development time. Default: Amplify.
3. **`kit/` as `android-library` vs `java-library`.** If `kit/` could avoid Android dependencies it would build faster and be easier to unit test. But Amplify pulls in Android transitively, so `android-library` is likely required. Revisit if Amplify is replaced.
4. **Rich text compose (Markdown-canonical).** The export target is **Markdown, not HTML** -- the first-party composers persist Markdown and emit the Markdown source as the text part so drafts round-trip losslessly across clients (see Phase 5). Compose's `TextField` with `AnnotatedString` supports basic formatting but has no built-in toolbar; the open question is only the *editor surface*: a minimal custom toolbar (bold/italic/link/list) over a Markdown buffer, versus a WebView-hosted editor reusing the same `marked.js`/`turndown.js` pipeline the Apple/web composers use for byte-parity. The canonical format is settled either way. Spike in Phase 5.
5. **Cross-device draft sync -- resolved.** `/save_draft` shipped (0.10.x) and the Apple clients use it; the Android client syncs drafts server-side rather than staying local-only (see Phase 5 and [`docs/draft-sync-and-threading.md`](../draft-sync-and-threading.md)). No new Lambda needed.
