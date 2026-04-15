# Native Apple Client Plan

## Context

The React admin app (`react/admin/`) currently serves as the only Cabalmail client. It works well, but it is a browser app with browser idioms — and even wrapped in a WebView it would feel out of place on iOS, iPadOS, visionOS, and macOS. Version 0.6.0 introduces a first-class native client that mirrors the *user-facing* portions of the React app (mail reading/compose/send, folder management, address creation and revocation, on-the-fly `From` addresses) without porting any of its code.

Administrative functionality introduced in 0.5.0 (user management, DMARC reports, multi-user address assignment) is out of scope. Admins will continue to use the web app for those workflows.

Scope of "Apple client" for 0.6.0:
- **iOS** and **iPadOS** (iPhone + iPad, shared target with adaptive layouts)
- **macOS** via Mac Catalyst *or* a native AppKit/SwiftUI target — decision in Phase 1
- **visionOS** as a secondary target sharing the iOS codebase

App Store public release is explicitly *not* a 0.6.0 goal — the roadmap places that at 1.4.0. This phase produces a working client that is continuously built and tested in CI and distributable via TestFlight internal groups.

## Approach

Seven phases: project scaffolding and shared Swift package; **CI/CD (early, so every subsequent phase runs through it)**; authentication and networking; mail reading; mail composition including on-the-fly `From`; address and folder management; platform polish and multiplatform layouts. The API surface already exists — every screen maps to one or more existing endpoints in `lambda/api/`.

### Guiding principles

- **Native idioms over parity.** Where the React app uses a custom widget, the Apple client uses the equivalent system control: `NavigationSplitView`, `List`, `.searchable`, `Menu`, share sheet, `.contextMenu`, swipe actions, etc. The goal is an app that feels at home next to Mail.app, not a translation of the web UI.
- **SwiftUI first.** Use SwiftUI for all new views. Drop to UIKit/AppKit only where SwiftUI lacks a capability (e.g. rich-text composition on some OS versions — see Phase 5).
- **Reuse the existing API.** No new Lambdas are required. The same endpoints that back the React app back the Apple client, including Cognito auth (USER_SRP_AUTH).
- **No code sharing with the web app.** Swift types mirror the shapes returned by the Lambdas but are defined fresh. Sharing is limited to the *contract* (endpoint paths, JSON shapes), documented in the Swift package.
- **One Xcode project, multiple targets.** iOS/iPadOS/visionOS share a single app target; macOS is a separate target sharing the same Swift package.
- **CI from day one.** The Apple workflow lands in Phase 2 against the empty scaffold. Every subsequent phase is developed under green CI, not alongside it.

### Repository layout

A new top-level directory, sibling to `react/admin`:

```
apple/
  Cabalmail.xcworkspace
  Cabalmail/                   # iOS/iPadOS/visionOS app target
    CabalmailApp.swift
    Assets.xcassets
    Info.plist
    Views/
    ViewModels/
  CabalmailMac/                # macOS app target (if not using Catalyst)
  CabalmailKit/                # Swift package: networking, models, auth, caching
    Package.swift
    Sources/CabalmailKit/
    Tests/CabalmailKitTests/
  README.md
```

---

## Phase 1: Project Scaffolding & Shared Package

### 1. Xcode project

Create `apple/Cabalmail.xcworkspace` containing:
- `Cabalmail` app target: iOS 18+, iPadOS 18+, visionOS 2+ deployment targets, SwiftUI lifecycle (`@main App`).
- `CabalmailKit` Swift package: the shared networking/models/auth layer, consumed by every app target.
- A macOS target — decision point: **Mac Catalyst** (lowest effort, reuses iOS views verbatim) vs **native macOS target** (more idiomatic, separate `Scene` / window management, `Settings` scene, menu bar). Default is **native macOS target** because the roadmap treats macOS as a first-class platform; revisit if Phase 7 polish reveals unacceptable duplication.

### 2. Runtime configuration

The React app fetches `/config.js` at runtime from CloudFront, supplying `api_url`, `host`, Cognito IDs, and the list of mail domains. The Apple client needs the same values but cannot execute `config.js`.

Two options, pick one in Phase 1:

- **Option A (recommended): publish a signed JSON config.** Add a new Terraform-managed object at `https://{control_domain}/config.json` with the same values `config.js` currently emits. The Apple client fetches it on first launch and caches it in `UserDefaults`. Requires a one-line addition in `terraform/infra/modules/app/` (or the module that writes `config.js`) to emit a JSON sibling.
- **Option B: bundle the config at build time.** Ship `Config.xcconfig` values per build configuration (dev/stage/prod). Simpler but couples the app version to an environment.

Option A is preferred because it keeps the client environment-agnostic (same IPA works against dev/stage/prod by pointing at a different control domain).

### 3. `CabalmailKit` — scaffolding

- `Package.swift` declaring platforms (iOS 18, macOS 15, visionOS 2) and product `CabalmailKit`.
- Folders: `Models/`, `API/`, `Auth/`, `Cache/`, `Config/`.
- Placeholder `CabalmailClient` actor that will own the auth session and API surface.
- Unit test target with a single smoke test.

### Phase 1 Verification

1. `xcodebuild -workspace apple/Cabalmail.xcworkspace -scheme Cabalmail -destination 'generic/platform=iOS' build` succeeds.
2. `xcodebuild test -scheme CabalmailKit` succeeds.
3. Empty iOS app launches in the simulator and shows a placeholder "Hello, Cabalmail" view.

---

## Phase 2: CI/CD

Land the Apple workflow against the Phase 1 scaffold so every subsequent phase develops under green CI. GitHub Actions supports Apple builds on its `macos-14` / `macos-15` hosted runners (Apple Silicon, Xcode preinstalled). The new workflow lives alongside the existing `.github/workflows/` pipelines, mirroring their conventions (branch → environment mapping, path-based triggers, shared `.github/scripts/` helpers where applicable).

### 1. Workflow layout

**`.github/workflows/apple.yml`** — triggers on `apple/**` path changes, pushes to `main`/`stage`, and manual `workflow_dispatch`. Four jobs:

| Job | Runner | Purpose |
|---|---|---|
| `kit-test` | `macos-15` | Build and test `CabalmailKit` across iOS, macOS, visionOS destinations (matrix) |
| `app-build` | `macos-15` | `xcodebuild archive` for the iOS/iPadOS/visionOS app and the macOS app (matrix of two) |
| `upload-ios` | `macos-15` | Sign the iOS archive, export `.ipa`, upload to TestFlight (runs on `main` → prod group; `stage` → internal group) |
| `upload-mac` | `macos-15` | Notarize and staple the macOS archive; upload to TestFlight and attach as a release artifact |

Environment mapping follows the existing repo convention: `main` → prod, `stage` → stage, other branches → development (build + test only; upload jobs skip).

### 2. Toolchain pinning

- `maxim-lobanov/setup-xcode@v1` with an explicit `xcode-version` (e.g. `'16.1'`) so builds are reproducible across runner image rotations.
- `actions/cache` for `~/Library/Developer/Xcode/DerivedData` and Swift Package Manager artifacts, keyed on hashes of `Package.resolved` and `project.pbxproj`. Target: warm `app-build` under 10 minutes.
- Simulator destinations specified explicitly (`'platform=iOS Simulator,name=iPhone 16,OS=18.1'`, `'platform=visionOS Simulator,name=Apple Vision Pro'`) — simulator lists vary by runner image.

### 3. Linting

- `swiftlint` runs in `kit-test` on both `CabalmailKit/` and the app sources, mirroring the existing `pylint` / `tflint` jobs.
- `xcodebuild` warnings promoted to errors for release configurations.

### 4. Code signing

- **Certificates**: export the Apple Distribution certificate as a `.p12`, base64-encode, store as `APPLE_DISTRIBUTION_CERT_P12` and `APPLE_DISTRIBUTION_CERT_PASSWORD` secrets. At job start, import into a temporary keychain (`security create-keychain`, `security import`, `security set-key-partition-list`).
- **Provisioning profiles**: fetched at CI time via the App Store Connect API (rotation-free), or base64-encoded in secrets as a fallback.
- **App Store Connect API key**: store `APP_STORE_CONNECT_API_KEY_ID`, `APP_STORE_CONNECT_API_ISSUER_ID`, and the `.p8` key (base64) as secrets. Used for provisioning-profile fetch and TestFlight upload.

### 5. TestFlight & notarization

- **TestFlight upload**: `xcrun altool --upload-app` with the App Store Connect API key. Build number is `${{ github.run_number }}` for monotonicity; marketing version read from `Info.plist`. A post-upload step posts the TestFlight build URL to the workflow summary.
- **Notarization (macOS)**: `xcrun notarytool submit --wait` followed by `xcrun stapler staple`.

### 6. Cost note

macOS runners bill at a **10× multiplier** on paid plans. The workflow's path filters (`apple/**`) keep cost bounded — unrelated PRs don't trigger it. If iteration becomes painful, self-hosted Apple Silicon is a fallback, at the cost of operational burden.

### Phase 2 Verification

1. Open a PR touching `apple/**` (even a README change); confirm `kit-test` and `app-build` run and pass against the Phase 1 scaffold.
2. Confirm the workflow does **not** run when only `react/**`, `lambda/**`, or `terraform/**` change.
3. Confirm cache hits on a second run reduce `app-build` wall-clock noticeably.
4. Merge to `stage`; confirm a signed iOS build uploads to the stage TestFlight group and the macOS build is notarized and stapled.

---

## Phase 3: Authentication & Networking

### 1. Cognito authentication

The React app uses `amazon-cognito-identity-js` for SRP auth, JWT storage, and refresh. The Apple analog is **AWS Amplify Swift** (`Amplify` + `AWSCognitoAuthPlugin`), which wraps the same SRP flow and handles token refresh natively.

`CabalmailKit/Sources/CabalmailKit/Auth/AuthService.swift`:
- `func signIn(username:password:) async throws -> AuthSession`
- `func signUp(username:password:email:phone:) async throws`
- `func confirmSignUp(username:code:) async throws`
- `func forgotPassword(username:) async throws` / `confirmForgotPassword(username:code:newPassword:)`
- `func signOut() async`
- `func currentIdToken() async throws -> String` — always returns a fresh token, refreshing if needed

Amplify stores tokens in the iOS/macOS Keychain automatically. Good.

**Alternative if Amplify's footprint is objectionable:** implement SRP directly against the Cognito IdP `InitiateAuth` / `RespondToAuthChallenge` endpoints using `URLSession`. The React app's `amazon-cognito-identity-js` is a reference implementation of the wire protocol. This is maybe a week of work and removes ~2 MB of Amplify dependencies. Decide in Phase 3; default to Amplify for velocity.

### 2. API client

`CabalmailKit/Sources/CabalmailKit/API/ApiClient.swift` — an actor that mirrors `react/admin/src/ApiClient.js` method-for-method:

| API method | HTTP | Endpoint | Notes |
|---|---|---|---|
| `listAddresses()` | GET | `/list` | |
| `newAddress(...)` | POST | `/new` | |
| `revokeAddress(address)` | DELETE | `/revoke` | |
| `listFolders()` | GET | `/list_folders` | |
| `newFolder(name)` | POST | `/new_folder` | |
| `deleteFolder(name)` | DELETE | `/delete_folder` | |
| `subscribeFolder(name)` / `unsubscribeFolder(name)` | PUT | `/subscribe_folder`, `/unsubscribe_folder` | |
| `listEnvelopes(folder:range:)` | GET | `/list_envelopes` | Paginated |
| `fetchMessage(folder:id:)` | GET | `/fetch_message` | S3-cached on the server |
| `listAttachments(folder:id:)` / `fetchAttachment(folder:id:part:)` | GET | | |
| `fetchInlineImage(folder:id:cid:)` | GET | | |
| `send(...)` | POST | `/send` | Multipart for attachments |
| `moveMessages(folder:ids:target:)` | PUT | `/move_messages` | |
| `setFlag(folder:ids:flag:set:)` | PUT | `/set_flag` | |
| `fetchBimi(domain)` | GET | `/fetch_bimi` | |

Each method is `async throws` and returns a typed `Codable` model. IMAP folder paths use `/` in the URL (matching the existing Lambdas' `.replace("/", ".")` normalization).

All requests attach `Authorization: <idToken>` via a shared `URLRequest` interceptor that calls `authService.currentIdToken()`. 401s trigger a single retry after a forced refresh; a second 401 surfaces as `AuthError.expired`.

### 3. Caching

Mirror the React app's behavior where sensible, using `URLCache` for GET responses and an explicit in-memory actor for `ADDRESS_LIST` / `FOLDER_LIST` equivalents. Invalidation on mutation matches the React `localStorage.removeItem(...)` pattern in `ApiClient.js`.

### Phase 3 Verification

1. Unit tests in `CabalmailKitTests` against a mocked `URLProtocol` cover token attachment, 401 retry, and each endpoint's request shape. These run in `kit-test` on every PR.
2. Manual: sign in on a dev build against the dev environment; confirm a JWT lands in Keychain and `listAddresses()` returns the expected addresses.
3. Manual: force-expire the token (wait out the expiry or clear the Keychain entry) and confirm the client recovers silently.

---

## Phase 4: Mail Reading

First user-visible feature: a functional read-only mail client.

### 1. Folder sidebar

`Cabalmail/Views/FolderListView.swift` — a SwiftUI `List` backed by `listFolders()`. On iPhone, folders are the root view; on iPad/macOS/visionOS, folders occupy the leading column of a `NavigationSplitView`.

- Inbox pinned to the top, then user folders, then system folders (Sent, Drafts, Trash, Junk) grouped.
- Unread counts shown as trailing badges (requires a future enhancement on `list_folders` to return counts, or a lazy per-folder fetch — Phase 4 starts without counts and adds them in Phase 7).
- Pull-to-refresh (`.refreshable`) to reload.

### 2. Message list

`Cabalmail/Views/MessageListView.swift` — middle column of the split view, or pushed view on iPhone.

- Backed by `listEnvelopes(folder:range:)` with page-based lazy loading (`onAppear` on the last row fetches the next page).
- Each row shows sender, subject, snippet, date, read/unread dot, attachment paperclip, flag.
- Swipe actions: archive/trash (left), flag/mark-read (right) — wiring to `moveMessages` and `setFlag`.
- `.searchable` wired to a client-side filter initially; server-side IMAP search is a Phase 7 nice-to-have.
- `.contextMenu` mirrors the swipe actions for Mac/iPad pointer users.

### 3. Message view

`Cabalmail/Views/MessageDetailView.swift` — trailing column / pushed detail.

- Headers block: From (with avatar placeholder and BIMI logo via `fetchBimi`), To/Cc, date, subject.
- Body: HTML bodies render in a `WKWebView` wrapper (`UIViewRepresentable`) with a restrictive content policy — no remote content by default, a "Load remote content" toolbar button reveals it. Plain-text bodies render in a `Text` with `.textSelection(.enabled)`.
- Inline images resolved via `fetchInlineImage` and rewritten into the HTML before it is loaded.
- Attachments shown in a horizontal scroller below the body; tap opens `QLPreviewController` / `NSPreviewPanel` using a file downloaded via `fetchAttachment` to a temporary directory.

### 4. Sanitization

The React app uses DOMPurify. The Apple client's `WKWebView` runs in a non-persistent `WKWebsiteDataStore` with JavaScript disabled by default and all network requests blocked by a `WKContentRuleList`. Rich HTML displays correctly; scripts, trackers, and remote fetches do not.

### Phase 4 Verification

1. Manual on iPhone simulator: sign in, browse folders, read a message with attachments, download an attachment.
2. Manual on iPad simulator: confirm three-column layout renders, column widths behave on rotation, keyboard shortcuts (↑/↓/Return) navigate the message list.
3. Manual on Mac: confirm native window chrome, menu bar File > New Window creates a second window with independent state.
4. Manual: open a message containing remote tracking pixels; confirm no network request fires until "Load remote content" is tapped.

---

## Phase 5: Mail Composition & On-the-Fly `From`

This is the feature that differentiates Cabalmail from a generic IMAP client.

### 1. Compose scene

`Cabalmail/Views/ComposeView.swift` — presented as a sheet on iPhone, a new window on iPadOS/macOS (using `openWindow` with a value-based `WindowGroup`), and a volumetric window on visionOS.

Fields:
- **From** — a `Menu` / `Picker` seeded with `listAddresses()`. The list ends with a "**Create new address…**" item that presents an inline sheet (subdomain picker + local-part field + comment) and calls `newAddress`; on success, the new address is selected and the picker closes.
- **To**, **Cc**, **Bcc** — token fields with contact autocomplete (sourced from the system contacts store with explicit permission and/or a learned frequency list stored in `CabalmailKit/Cache/`).
- **Subject** — plain text field.
- **Body** — rich-text composition. SwiftUI `TextEditor` with `AttributedString` on iOS 18+/macOS 15+ handles bold/italic/links/lists. For OS versions where attributed `TextEditor` is insufficient, wrap `UITextView` / `NSTextView` as `UIViewRepresentable` / `NSViewRepresentable`. Toolbar provides formatting controls plus an "Attach" button using `PhotosPicker` and `fileImporter`.

Sending invokes `ApiClient.send` with a multipart body. While sending, the compose window shows a progress overlay; on success it dismisses; on failure it remains open with an error banner.

### 2. Reply / Reply All / Forward

Triggered from the message detail toolbar. The compose scene opens pre-populated:
- **From** defaults to the address the original was sent *to* (matching the React app's behavior per 0.3.0 roadmap entry). If that address was multi-recipient, the first that exists in the user's address list is chosen.
- **To** / **Cc** populated per reply semantics.
- **Subject** prefixed with `Re:` or `Fwd:` if not already.
- **Body** quotes the original with attribution line.

### 3. Drafts

Drafts persist locally in Core Data (or a lightweight Swift `Codable` store in the app's support directory). Autosave every 5 seconds while editing. A "Drafts" row in the folder sidebar shows local drafts first, then IMAP drafts (from `Drafts` folder) — with a visible separator. Local drafts are promoted to IMAP drafts on a manual "Save to Server" action (Phase 7 could automate this).

### Phase 5 Verification

1. Manual: compose and send to a personal address, confirm delivery and correct `From`.
2. Manual: in compose, open the From picker, create a new address, confirm it becomes the selected From and appears in the Addresses tab.
3. Manual: reply to a message, confirm From defaults to the addressee of the original.
4. Manual: kill the app mid-compose, relaunch, confirm draft restored.

---

## Phase 6: Address & Folder Management

Non-mail features from the React app, given their own tabs (iPhone) or sidebar sections (iPad/macOS/visionOS).

### 1. Addresses tab

`Cabalmail/Views/AddressesView.swift` — mirrors `react/admin/src/Addresses/`:
- Section "My Addresses": every address owned by the user, with a trailing revoke button (`.swipeActions` + long-press `.contextMenu`, confirmation alert).
- Section "Request New": form with subdomain picker, local-part field, comment, and "Create" button. Same validation rules as the web form (local-part regex, collision check via `newAddress` response).
- Pull-to-refresh.

### 2. Folders tab

`Cabalmail/Views/FoldersAdminView.swift` — mirrors `react/admin/src/Folders/`:
- List of subscribed folders with unsubscribe action.
- List of unsubscribed (but present on server) folders with subscribe action.
- "New Folder" button presenting a sheet with a name field and a parent-folder picker.
- Delete action on empty user folders with confirmation.

### 3. Settings / Profile

A new area with no React analog:
- Signed-in account, sign-out button.
- Default From address (used when compose is opened outside a reply context).
- Signature (stored locally, appended at compose time).
- "Load remote content in messages" default (off / ask / on).
- Appearance (system / light / dark), matching the Light/Dark CSS split in `react/admin/src/App*.css`.
- About / version / link to GitHub issues.

### Phase 6 Verification

1. Manual: create, then revoke an address; confirm it disappears from the picker in Compose.
2. Manual: create a nested folder, subscribe/unsubscribe, delete; confirm changes reflect in the sidebar.
3. Manual: change signature, compose a new message, confirm signature appended.

---

## Phase 7: Platform Polish

Cross-cutting work to make each platform feel native, plus robustness improvements.

### 1. iPhone

- Tab bar with Mail / Addresses / Folders / Settings.
- Swipe actions tuned to match Mail.app defaults.
- Dynamic Type + high-contrast audit.

### 2. iPad

- `NavigationSplitView` (folders | messages | detail) with `.balanced` column visibility.
- Keyboard shortcuts (⌘N compose, ⌘R reply, ⌘⇧D reply-all, ⌘F search, j/k navigation).
- Stage Manager / external display verified.
- Multiple scenes (`.handlesExternalEvents`) — compose in its own scene.

### 3. macOS

- Menu bar: File (New Message ⌘N, New Window ⌘⇧N), Mailbox (Get New Mail ⌘⇧N, Go to Folder…), Message (Reply, Reply All, Forward, Move To…, Flag, Archive), View (Sort / Group).
- Toolbar customization via `.toolbar(customizationBehavior:)`.
- `Settings` scene for preferences (replaces the mobile Settings tab on macOS).
- AppKit `NSSharingServicePicker` for share actions where SwiftUI `ShareLink` is insufficient.

### 4. visionOS

- Ornaments for the compose scene's toolbar.
- Glass-background materials for the folder sidebar.
- Hover effects on list rows.
- Window sizing respectful of `WindowGroup` defaults (folders+messages in one window; compose and detail open as side volumes / additional windows).

### 5. Unread counts and background refresh

- Extend `list_folders` (or add a sibling `list_folder_counts` endpoint) to return unread counts. (This is the one API change required for the Apple client — track as a separate ticket.)
- `BGAppRefreshTask` on iOS / `NSBackgroundActivityScheduler` on macOS fetches envelopes for subscribed folders so unread badges are fresh at launch. Full push via APNs is deferred past 0.6.0 — it requires a server-side watcher process the current container architecture does not run.

### 6. Offline reading

- Recently viewed messages (last 50 per folder) persisted to disk via the existing S3-cached raw source (`fetch_message` already serves from S3 after first read; locally we cache the parsed response).
- Starred / flagged messages pinned in cache indefinitely.
- Offline banner shown when reachability drops; composed messages queue and send on reconnect.

### 7. Error handling and telemetry

- Structured `CabalmailError` type; user-facing messages mapped per case.
- Opt-in crash reporting via `MetricKit` (no third-party SDK).
- Debug log view in Settings (last 1000 log lines in memory) for troubleshooting.

### Phase 7 Verification

1. Manual per platform: run through the golden path (sign in → browse → read → reply → send → revoke address) and confirm it feels native.
2. Accessibility Inspector audit on iOS and macOS — zero critical issues.
3. Airplane mode test: confirm cached messages remain readable; confirm queued sends fire on reconnect.

---

## Out of Scope for 0.6.0

- **App Store public release.** Tracked as 1.6.0. 0.6.0 produces builds distributable via TestFlight internal groups (automated via CI in Phase 2).
- **Push notifications.** Requires new server-side infrastructure (IMAP IDLE watcher, APNs bridge) not present in the 0.4.0 container architecture.
- **Admin features** (user management, DMARC, multi-user address assignment from 0.5.0). Admins continue to use the web app.
- **RSS reader.** Tracked as 2.x.
- **Android client.** Tracked separately starting at 1.1.0.

## Prerequisites

- **Apple Developer account** enrolled, with the team ID, Apple Distribution certificate, and App Store Connect API key available to add as GitHub secrets before Phase 2 lands.
- **App identifiers** registered in App Store Connect for the iOS/iPadOS/visionOS app and the macOS app.

## Open Questions

1. **Mac Catalyst vs native macOS target** — decide in Phase 1 after a spike.
2. **Amplify Swift vs hand-rolled Cognito SRP** — decide in Phase 3 based on Amplify's binary size on an empty project.
3. **Unread count endpoint** — add to `list_folders` or new endpoint? Light preference for a new endpoint to keep `list_folders` cheap.
