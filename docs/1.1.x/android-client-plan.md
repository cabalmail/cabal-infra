# Native Android Client Plan

## Context

The React admin app (`react/admin/`) and native Apple clients (`apple/`) currently serve as the Cabalmail clients. Version 1.1.0 introduces a native Android client that mirrors the *user-facing* portions of the Apple client (mail reading/compose/send, folder management, address creation and revocation, on-the-fly `From` addresses) without sharing code with either existing client.

Administrative functionality (user management, DMARC reports, multi-user address assignment) is out of scope. Admins will continue to use the web app for those workflows.

Scope of "Android client" for 1.1.0:
- **Android phone** and **tablet** (single codebase with adaptive layouts via Compose `WindowSizeClass`)
- **ChromeOS** compatibility comes for free via the phone/tablet target
- **Foldables** handled automatically by Compose's adaptive layout primitives

Wear OS, Android TV, and Android Auto are explicitly out of scope.

Play Store public release is explicitly *not* a 1.1.0 goal -- the roadmap places that at 1.5.0. This phase produces a working client that is continuously built and tested in CI and distributable via Play Console internal testing tracks.

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
| `APPEND` for sent/drafts | `/send` handles Outbox + Sent server-side | Same -- no client-side APPEND |
| MIME parsing for `fetchPart` | Fetch full body, parse MIME client-side | Same approach in Kotlin |

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
| `listEnvelopes(folder, page)` | GET | `/list_envelopes` | Paginated envelope list |
| `fetchMessage(folder, uid)` | GET | `/fetch_message` | Full RFC 822 body |
| `listAttachments(folder, uid)` | GET | `/list_attachments` | Attachment metadata |
| `fetchAttachment(folder, uid, part)` | GET | `/fetch_attachment` | Returns presigned S3 URL |
| `fetchInlineImage(folder, uid, part)` | GET | `/fetch_inline_image` | Inline image data |
| `setFlag(folder, uids, flag, value)` | POST | `/set_flag` | Set/clear IMAP flags |
| `moveMessages(folder, uids, dest)` | POST | `/move_messages` | Move between folders |
| `send(message)` | POST | `/send` | Send; handles Outbox + Sent server-side |
| `listAddresses()` | GET | `/list` | User's addresses |
| `newAddress(subdomain, local, comment)` | POST | `/new` | Create address |
| `revokeAddress(address)` | DELETE | `/revoke` | Delete address |
| `fetchBimi(domain)` | GET | `/fetch_bimi` | BIMI logo lookup |
| `listFoldersAdmin()` | GET | `/list_folders` | For folder management |
| `newFolder(name, parent)` | POST | `/new_folder` | Create folder |
| `deleteFolder(name)` | DELETE | `/delete_folder` | Delete folder |
| `subscribeFolder(name)` | POST | `/subscribe_folder` | Subscribe |
| `unsubscribeFolder(name)` | POST | `/unsubscribe_folder` | Unsubscribe |

Ktor client configuration:
- `ContentNegotiation` with `kotlinx.serialization` for JSON
- `HttpTimeout` (30s connect, 60s request)
- `Logging` plugin at `LogLevel.HEADERS` for debug builds only
- `HttpResponseValidator` for structured error mapping

### 3. Models

`kit/src/main/kotlin/com/cabalmail/kit/models/` -- Kotlin data classes with `@Serializable`:

- `Config` -- runtime configuration from `config.json`
- `Folder` -- name, delimiter, attributes, unread count
- `Envelope` -- uid, from, to, cc, subject, date, flags, hasAttachments, size
- `Message` -- envelope + raw body (RFC 822)
- `Address` -- address string, subdomain, local part, comment, domain
- `Attachment` -- filename, content type, size, part ID
- `BimiLogo` -- SVG URL or image data

### 4. Caching

- **Envelope cache**: `Room` database keyed by `(folder, uid)`. On reconnect, fetch only UIDs newer than the last cached UID.
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

- Backed by `ApiClient.listEnvelopes(folder, page)` with page-based lazy loading (`LazyColumn` with `onAppear`-equivalent triggering next page fetch when the last item is composed).
- Each row: sender, subject, snippet, date, read/unread indicator (from `\Seen`), attachment icon (from envelope metadata), flag indicator (from `\Flagged`).
- Swipe actions via `SwipeToDismissBox`: swipe left -> `moveMessages` to Archive or Trash per the "Dispose action" setting (default: Archive); swipe right -> toggle flag/mark-read via `setFlag`.
- `SearchBar` wired to the `/list_envelopes` search parameter -- server-side search.
- Long-press context menu mirrors swipe actions for accessibility and discoverability.

### 3. Message detail

`app/.../ui/mail/MessageDetailScreen.kt` -- trailing pane on tablet, or navigated-to screen on phone.

- Headers: From (with BIMI logo via `ApiClient.fetchBimi`), To/Cc, date, subject.
- Body: fetched via `ApiClient.fetchMessage(folder, uid)`. Messages are never auto-marked-as-read by default -- the user explicitly marks read via swipe, toolbar button, or context menu. An opt-in "mark read on open" setting is available (Phase 6) but defaults to off.
- MIME parsed client-side. HTML bodies render in an Android `WebView` (`AndroidView` composable wrapper) with restrictive settings:
  - `settings.javaScriptEnabled = false`
  - Custom `WebViewClient` that intercepts all URL loads and blocks remote content by default
  - `WebSettings.setBlockNetworkLoads(true)` unless the user taps "Load remote content"
  - `setWebContentsDebuggingEnabled(false)` in release builds
- Plain-text bodies render in a `SelectionContainer { Text(...) }`.
- Inline images resolved by fetching via `ApiClient.fetchInlineImage` and injecting as `data:` URIs into the HTML before loading.
- Attachments shown in a horizontal `LazyRow` below the body; tap downloads via `ApiClient.fetchAttachment` (presigned URL) and opens with `ACTION_VIEW` intent or the system file viewer.

### 4. Sanitization

No JavaScript execution. Remote content blocked by default via `WebSettings.setBlockNetworkLoads(true)`. A toolbar button ("Load remote content") toggles network loads for the current message only -- does not persist. This mirrors the Apple client's `WKWebView` approach.

### Phase 4 verification

1. Manual on phone emulator (Pixel 8, API 35): sign in, browse folders, read a message with attachments, download an attachment.
2. Manual on tablet emulator (Pixel Tablet, API 35): confirm adaptive layout renders folder list + message list side by side, detail opens in trailing pane.
3. Manual: open a message containing remote tracking pixels; confirm no network request fires until "Load remote content" is tapped.
4. Manual: pull-to-refresh on the message list; confirm new messages appear.

---

## Phase 5: Mail Composition & On-the-Fly `From`

The feature that differentiates Cabalmail from a generic mail client.

### 1. Compose screen

`app/.../ui/compose/ComposeScreen.kt` -- presented as a full-screen activity on phone, or a dialog/new window on tablet.

Fields:
- **From** -- an `ExposedDropdownMenuBox` seeded with `listAddresses()`, **no preselection by default**. The Send button is disabled until the user selects or creates an address. If the user has set a default From address in Settings, that address is preselected instead. The menu ends with a "**Create new address...**" item that opens a bottom sheet (subdomain picker + local-part field + comment) and calls `newAddress`; on success, the new address is selected.
- **To**, **Cc**, **Bcc** -- chip-based input fields. Contact autocomplete from the system `ContactsContract` provider (with runtime permission) and/or a learned frequency list in Room.
- **Subject** -- plain `TextField`.
- **Body** -- rich text via a `TextField` with `AnnotatedString` support, or a minimal rich-text editor (bold/italic/links/lists). Toolbar provides formatting controls plus an "Attach" button using the Photo Picker (`PickVisualMedia` contract on API 33+, `ACTION_OPEN_DOCUMENT` fallback on 31-32) and the document picker (`OpenDocument` contract).
- **Send** builds the message and submits via `ApiClient.send()`. The `/send` endpoint handles Outbox + Sent server-side (no client-side APPEND). While sending, the compose screen shows a progress indicator; on success it dismisses; on failure it remains open with a `Snackbar` error.

### 2. Reply / Reply All / Forward

Triggered from the message detail toolbar. The compose screen opens pre-populated:
- **From** defaults to the address the original was sent *to* (matching 0.3.0 behavior). If multi-recipient, the first that exists in the user's address list is chosen.
- **To** / **Cc** populated per reply semantics.
- **Subject** prefixed with `Re:` or `Fwd:` if not already.
- **Body** quotes the original with attribution line.

### 3. Drafts

Drafts persist locally while being edited (Room database, autosaving every 5 seconds). On compose-screen close *without* send, the draft remains in Room for the next session. Cross-device draft sync (via IMAP `Drafts` folder) is deferred -- the API surface doesn't expose `APPEND` directly, and `/send` is the only write path. Local-only drafts are sufficient for 1.1.0.

### 4. Share target

Register the app as a share target (`<intent-filter>` with `ACTION_SEND` / `ACTION_SEND_MULTIPLE`) so users can share text, images, and files from other apps directly into the compose screen. The shared content populates the body and/or attachments.

### Phase 5 verification

1. Manual: compose and send to a personal address, confirm delivery and correct `From`.
2. Manual: in compose, open the From picker, create a new address, confirm it becomes the selected From and appears in the Addresses screen.
3. Manual: reply to a message, confirm From defaults to the addressee of the original.
4. Manual: kill the app mid-compose, relaunch, confirm draft restored.
5. Manual: share an image from the Photos app into Cabalmail; confirm it appears as an attachment in compose.

---

## Phase 6: Address & Folder Management + Settings

Non-mail features, given their own destinations in the navigation graph.

### 1. Addresses screen

`app/.../ui/addresses/AddressesScreen.kt` -- mirrors the Apple Addresses tab:
- Section "My Addresses": `ApiClient.listAddresses()`, with swipe-to-delete and long-press context menu calling `ApiClient.revokeAddress` (with confirmation dialog).
- Section "Request New": bottom sheet with subdomain picker (`ExposedDropdownMenuBox`), local-part field, comment field, and "Create" button calling `ApiClient.newAddress`. Same validation rules as the web and Apple apps.
- Pull-to-refresh.

### 2. Folders screen

`app/.../ui/folders/FoldersAdminScreen.kt` -- mirrors the Apple Folders tab:
- Full folder list from `ApiClient.listFolders()`; subscribed/unsubscribed state shown.
- Subscribed folders get an unsubscribe action; unsubscribed folders get a subscribe action.
- "New Folder" FAB opening a dialog with name field and parent-folder picker.
- Delete action on empty user folders with confirmation dialog.

### 3. Settings

`app/.../ui/settings/SettingsScreen.kt` -- a dedicated navigation destination. All preferences stored via Jetpack `DataStore<Preferences>`.

**Account:**
- Signed-in account display, sign-out button.

**Reading:**

| Preference | Options | Default | Notes |
|---|---|---|---|
| Mark as read | Manual / On open / After delay (2s) | **Manual** | Manual = never set `\Seen` automatically. Matches the Apple client default. |
| Load remote content | Off / Ask / Always | **Off** | Controls whether `WebView` fetches remote resources. |

**Composing:**

| Preference | Options | Default | Notes |
|---|---|---|---|
| Default From address | None / (list of addresses) | **None** | None = From picker starts empty; Send blocked until user picks. When set, preselects in new-compose (replies still default to original addressee). |
| Signature | Text field | *(empty)* | Plain text, appended at compose time. |

**Actions:**

| Preference | Options | Default | Notes |
|---|---|---|---|
| Dispose action | Archive / Trash | **Archive** | Controls swipe-left and toolbar dispose throughout the app. |

**Appearance:**

| Preference | Options | Default | Notes |
|---|---|---|---|
| Theme | System / Light / Dark | **System** | Maps to `AppCompatDelegate.setDefaultNightMode()` or Compose `isSystemInDarkTheme()`. |
| Dynamic color | On / Off | **On** | Material You dynamic color from wallpaper. API 31 guarantees support. |

**About:**
- Version, build number, link to GitHub issues.

### Phase 6 verification

1. Manual: create, then revoke an address; confirm it disappears from the From picker in Compose.
2. Manual: create a nested folder, subscribe/unsubscribe, delete; confirm changes reflect in the folder list.
3. Manual: change signature, compose a new message, confirm signature appended.
4. Manual: open a message; confirm it stays unread (default: manual). Change setting to "On open"; open a message; confirm `\Seen` is set.
5. Manual: set Default From to an address; open a new compose; confirm preselected. Clear the setting; confirm From picker is empty and Send is disabled.
6. Manual: toggle theme to Dark; confirm immediate switch. Toggle Dynamic color off; confirm Material 3 falls back to the default seed color.

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
- Keyboard shortcuts via `onKeyEvent` for hardware keyboards: Ctrl+N compose, Ctrl+R reply, Ctrl+Shift+R reply all, j/k navigation.
- Foldable hinge-aware layout via `WindowInfoTracker` -- avoid placing content on the hinge.

### 3. Notifications

- Local notifications only (no FCM push -- same constraint as iOS without APNs).
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

- **Public Play Store release.** Tracked as 1.5.0. 1.1.0 ships to Play Console internal testers only.
- **Push notifications (FCM).** Same blocker as iOS/APNs: needs a server-side IDLE watcher to bridge to FCM. Tracked alongside APNs work.
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
4. **Rich text compose.** Jetpack Compose's `TextField` with `AnnotatedString` supports basic formatting but lacks a built-in toolbar or HTML export. Options: minimal custom toolbar (bold/italic/link only, export to HTML manually), or a third-party rich-text editor library. Spike in Phase 5.
5. **Cross-device draft sync.** The API surface doesn't expose IMAP `APPEND`. Drafts are local-only in 1.1.0. If cross-device drafts are important, a `/save_draft` Lambda could be added in a future version.
