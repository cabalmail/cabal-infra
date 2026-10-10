# Cabalmail Apple Client

Native iOS / iPadOS / visionOS / macOS / watchOS client for Cabalmail. The
original implementation plan is preserved at
[`docs/0.6.x/ios-client-plan.md`](0.6.x/ios-client-plan.md) for
historical context; this document describes the as-implemented state.

## Layout

```
apple/
  project.yml                # XcodeGen spec (generates Cabalmail.xcodeproj)
  Cabalmail.xcworkspace/     # Workspace referencing the generated project + kit package
  CabalmailUI/               # Shared app layer (views, view models, app state) as one
                             #   module, linked by both apps; see "Shared app layer" below
  Cabalmail/                 # iOS / iPadOS / visionOS app target: entry point, App Intents,
                             #   Info.plist, entitlements, asset catalogs
  CabalmailMac/              # Native macOS app target: entry point, menus, Settings
                             #   window, menu-bar extra, asset catalogs
  CabalmailWatch/            # Watch companion app (address management only),
                             #   embedded in the iOS product
  CabalmailKit/              # Shared Swift package — networking, models, auth, caching;
                             #   its second product, CabalmailShared, holds what the app
                             #   extensions share with the apps (see "Extension-shared
                             #   values" below)
```

## Bootstrap

The `.xcodeproj` is not committed. Generate it before opening the
workspace. The rich-text composer's marked + turndown bundles are also
not committed (see [Rich-text editor](#rich-text-editor-wkwebview-contenteditable--fetched-markedturndown))
— they materialize from `react/admin/node_modules/` via a sync script.
Run both before your first `swift test` or `xcodebuild`:

```sh
brew install xcodegen node    # one-time
cd apple
xcodegen generate
scripts/sync-vendored.sh      # fetches marked + turndown into CabalmailKit
open Cabalmail.xcworkspace
```

CI (`.github/workflows/apple.yml`) runs both steps before every
`xcodebuild` and `swift test` invocation, so contributors never need to
commit generated project files or vendored JS.

Re-run `scripts/sync-vendored.sh` any time `react/admin/package.json`
bumps the `marked` or `turndown` version (`swift test` will fail with a
missing-resource error if you skip it).

### Prerequisites for local builds

- **Xcode.app installed** (not just the Command Line Tools bundle). If you
  see `xcodebuild: error: tool 'xcodebuild' requires Xcode, but active
  developer directory '/Library/Developer/CommandLineTools' is a command
  line tools instance`, point `xcode-select` at your Xcode installation:
  ```sh
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  ```
- **Apple Developer Program membership.** Signed archives and TestFlight
  both require an enrolled team.
- **Repo not under an iCloud-synced directory.** iCloud writes
  `com.apple.FinderInfo` extended attributes mid-build, which
  `codesign` rejects with `resource fork, Finder information, or similar
  detritus not allowed`. Keep the checkout outside `~/Desktop` and
  `~/Documents` when those are synced, or clone to a path like `~/Code`.
- **Default DerivedData location.** Do not pass `-derivedDataPath` into
  the repo tree (for the same xattr reason). Omit the flag to use
  `~/Library/Developer/Xcode/DerivedData` instead.

## Verification

From `apple/` after `xcodegen generate`:

```sh
# 1. App builds for iOS (unsigned; signing is only needed for archive/upload)
xcodebuild -workspace Cabalmail.xcworkspace \
           -scheme Cabalmail \
           -destination 'generic/platform=iOS' \
           CODE_SIGNING_ALLOWED=NO \
           CODE_SIGNING_REQUIRED=NO \
           CODE_SIGN_IDENTITY="" \
           build

# 2. Kit package tests pass
swift test --package-path CabalmailKit

# 3. Launch in the simulator and see "Hello, Cabalmail".
#    Easiest path: open Cabalmail.xcworkspace in Xcode, pick the Cabalmail
#    scheme and any iPhone simulator your Xcode ships, and press ⌘R.
#
#    Headless equivalent (uses the default DerivedData location — do NOT
#    pass -derivedDataPath into the repo tree if the repo lives under an
#    iCloud-synced directory, or codesign will reject the .app with
#    "resource fork, Finder information, or similar detritus not allowed").
#    Pick any iPhone simulator name that exists in your `xcrun simctl list
#    devices` output:
SIM='iPhone 17 Pro'   # adjust to whatever your Xcode version ships

xcodebuild -workspace Cabalmail.xcworkspace \
           -scheme Cabalmail \
           -destination "platform=iOS Simulator,name=$SIM" \
           build

APP_PATH=$(xcodebuild -workspace Cabalmail.xcworkspace \
                      -scheme Cabalmail \
                      -destination "platform=iOS Simulator,name=$SIM" \
                      -showBuildSettings build 2>/dev/null \
           | awk '/ BUILT_PRODUCTS_DIR = /{print $3}')/Cabalmail.app
xcrun simctl boot "$SIM" 2>/dev/null || true
open -a Simulator
xcrun simctl install booted "$APP_PATH"
xcrun simctl launch booted com.cabalmail.Cabalmail
```

### Signing

`DEVELOPMENT_TEAM` is deliberately unset in `project.yml`. Three contexts:

| Context                             | How the team ID is supplied                                                                                                                                                            |
| ----------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Local (Xcode or `xcodebuild`)       | Copy `Local.xcconfig.example` → `Local.xcconfig` and fill in `DEVELOPMENT_TEAM`. Gitignored. `project.yml` references it via `configFiles`, so every target picks it up automatically. |
| Headless `build` without a team ID  | Pass `CODE_SIGNING_ALLOWED=NO` (see verification commands above)                                                                                                                       |
| Headless `archive` (CI upload jobs) | `xcodebuild ... DEVELOPMENT_TEAM=$APPLE_TEAM_ID archive`, team ID sourced from a GitHub secret. Command-line overrides beat the xcconfig, so CI doesn't need the file.                 |

Setup once:

```sh
cd apple
cp Local.xcconfig.example Local.xcconfig
# edit Local.xcconfig, set DEVELOPMENT_TEAM to your team ID
xcodegen generate
```

After that, plain `xcodebuild ... build` and `xcodebuild ... archive` both sign cleanly.

`Local.xcconfig` is also where a local build sets `CABALMAIL_CONTROL_DOMAIN`,
the control domain baked into the associated-domains entitlement so
password managers can match the app to the web app's saved login; CI
passes it on the archive command line. See
[password-autofill.md](password-autofill.md).

## Simulator testing and automation

Tooling for driving the full app in an iOS simulator — scripted
scenarios, agent-driven exploration, and reproducing bugs that only
surface in the real app.

### Sign-in-capable simulator build: `scripts/build-sim.sh`

```sh
cd apple
scripts/build-sim.sh            # build + install onto the booted simulator
scripts/build-sim.sh <UDID>     # ... onto a specific simulator
scripts/build-sim.sh -          # build only
```

The invocation it wraps is non-obvious, and getting it wrong produces an
app that *builds* but cannot sign in:

- It **omits** `CODE_SIGNING_ALLOWED=NO`. The CI build recipe strips
  entitlements, and sign-in then fails with keychain error `-34018`.
  Simulator ad-hoc signing (the default) is sufficient. Do not try to
  repair an unsigned build afterwards with `codesign --entitlements` —
  that produces launch denials.
- It **adds** `ENABLE_DEBUG_DYLIB=NO`, without which the notification
  service extension's preview-dylib link step fails on command-line
  builds.
- `ONLY_ACTIVE_ARCH=YES` keeps it quick.

### Driving the installed app: `Tools/SimDrive`

A small XCUITest command REPL. The host writes command files into an
exchange directory; the test executes each against the installed app and
writes a JSON result back. Because it runs inside XCUITest, it sees the
app's accessibility tree — the same interface VoiceOver uses — rather
than pixels.

```sh
cd apple/Tools/SimDrive
./simdrive start                          # boots the runner (blocks until ready)
./simdrive cmd launch                     # launch the app
./simdrive cmd tap id:folder.row.INBOX    # address controls by identifier
./simdrive cmd wait id:message.row.42 timeout:15
./simdrive cmd swiperow id:message.row.42 edge:trailing hold:2
./simdrive cmd dump                       # full accessibility tree
./simdrive stop
```

The full command grammar (`launch`, `activate`, `env`, `dump`, `sysdump`,
`sysapp`, `focus`, `tap`, `type`, `cmdv`, `orient`, `drag`, `swiperow`,
`pscroll`, `scroll`, `exists`, `wait`) is documented at the top of
`Tools/SimDrive/SimDriveUITests/SimDriveTests.swift`. Notes that keep
sessions out of known potholes:

- **Addressing controls.** App controls carry `accessibilityIdentifier`s
  in `area.control` form — `signin.username`, `mfa.verify`,
  `message.row.<uid>`, `folder.row.<path>`, `compose.subject`, and so
  on. Prefer `id:` queries over `text:` (label matching breaks when copy
  changes) and over `xy:` coordinates (which break on rotation and
  layout changes). When adding an identifier to a *row*, pair it with
  `.accessibilityElement(children: .contain)` — a bare identifier merges
  the row's subtree into one accessibility element, which hides revealed
  swipe buttons from both XCUITest and VoiceOver.
- **Secure fields.** A SwiftUI `SecureField` does not accept the
  keyboard assistant bar's Paste button, but does accept hardware Cmd-V.
  Seed the simulator pasteboard host-side and paste:

  ```sh
  printf %s "$PASSWORD" | ./simdrive pbcopy   # simctl pbcopy under the hood
  ./simdrive cmd tap id:signin.password
  ./simdrive cmd cmdv
  ```

  This keeps secrets out of the command files and the harness logs,
  which is the required handling.
- **Scrolling, and the visionOS restriction.** `scroll <query>
  dir:up|down` swipes *within* the element you name (`dir:down` reveals
  what is below it), which is the only scroll visionOS accepts: an
  application-anchored coordinate — what `drag from:… to:…` and `tap
  xy:…` use — fails there with `Failed to synthesize event: Received
  invalid scene ID (nil)` and takes the runner with it. Off-screen
  SwiftUI rows are `exists=false`, not merely unhittable, so no
  identifier reaches them until something scrolls them into existence.
  The element you name is only the gesture's anchor, so a section header
  is a perfectly good one.

  Say where you are going, not how far: `scroll <query> dir:down
  until:<query>` sweeps until the second element is on screen, up to a
  budget of eight sweeps. That is what a recorded recipe wants, and
  `amount:` cannot express it. A synthesized press-and-drag always
  flicks, so one sweep moves roughly 270 points of content on an
  874-point window whatever the arithmetic asked for and every `amount:`
  below about 0.3 is the same command; and the `amount:` path stops
  measuring when the element you named scrolls out of the tree, which is
  the usual case, so the same request travels a different distance
  depending on an anchor chosen for unrelated reasons. `until:` has to
  come last — the rest of the line is its query, which is how a label
  with spaces gets through.
- **Touch and trackpad are different input.** `drag` and `swiperow`
  synthesize touches; `pscroll` synthesizes pointer scrolling, which is
  what a trackpad's two-finger swipe sends on iPadOS. UIKit routes the two
  differently, so a control can answer one and ignore the other: the
  iPadOS 27 message-list swipe did exactly that until it gained a
  trackpad path of its own. Check both when changing anything a row
  swipe depends on.
- **Gestures hold the runner's main thread.** A swipe reveal cannot be
  observed from inside the runner mid-gesture. Use `drag ... hold:<s>`
  or `swiperow ... hold:<s>` and screenshot from *outside* during the
  hold (`xcrun simctl io <udid> screenshot out.png`).
- **First-run interruptions.** On a fresh simulator, expect an iPadOS
  "Copy and Paste" keyboard education overlay covering the form, and a
  "Save Password?" alert after sign-in (dismiss with `Not Now`). Script
  their dismissal (`tap text:Not Now`) or pre-seed the simulator before
  measuring anything.
- **UI the app does not own needs `sys` queries.** Permission alerts,
  AutoFill sheets, edit menus and the visionOS keyboard can live in a
  system process rather than the app's hierarchy — and when they do, an
  app-scoped query reports them absent while the app underneath stays
  inert until they are answered, so a `tap`/`type` that "succeeds" and
  changes nothing is the signature. Which UI lands where is not worth
  predicting: try `text:`/`id:` first, and when the element is missing
  but visible on a screenshot, re-run the query with the `sysid:` /
  `systext:` prefix. `sysdump` shows the system-side tree.
  The hosting process is probed, not assumed, because it differs by
  platform: iOS and iPadOS have `com.apple.springboard`, while visionOS
  has no SpringBoard at all and splits the shell across
  `com.apple.Reality*` processes. Every result reports which one
  answered (`tapped systext:Allow in com.apple.RealityNotifications`);
  `sysapp <bundleid>` pins one when a host is not on the candidate list.
- **MFA makes fresh simulators expensive.** Simulator keychains do not
  transfer between devices or runtimes, so every new simulator costs a
  full manual sign-in. Signed-in state *does* persist across reinstalls
  of the same bundle id on the same simulator — keep one designated
  signed-in simulator per runtime and record which.

## Apple Developer account setup

This is the one-time manual setup required to enable CI uploads to
TestFlight. Run through it in order once per team. Individual substeps
are expanded in the sections further down.

1. **Enroll the team** at
   [developer.apple.com](https://developer.apple.com/programs/) if it
   isn't already. Confirm your 10-character **Team ID** at
   [Membership details](https://developer.apple.com/account); this
   becomes the `APPLE_TEAM_ID` secret.
2. **Create the Apple Distribution certificate.** Xcode → Settings →
   Accounts → select your Apple ID and team → Manage Certificates… →
   **+ → Apple Distribution**. See [Exporting the distribution
   certificate](#exporting-the-distribution-certificate) for the export
   flow that produces `APPLE_DISTRIBUTION_CERT_P12` /
   `APPLE_DISTRIBUTION_CERT_PASSWORD`.
3. **(macOS only) Create a Mac Installer Distribution certificate.** The
   `.pkg` that wraps the `.app` at Mac App Store submission time needs
   its own cert — `Apple Distribution` signs the `.app`, Mac Installer
   Distribution signs the `.pkg`. See [Exporting the Mac Installer
   certificate](#exporting-the-mac-installer-certificate).
4. **Register the App Group and bundle identifiers** in the Developer
   portal at [developer.apple.com](https://developer.apple.com/account) →
   Certificates, Identifiers & Profiles → **Identifiers** → **+**.

   First the App Group (the shared container the push Notification
   Service Extension reads; select **App Groups** on the + screen):
   - `group.com.cabalmail.Cabalmail` (description: `Cabalmail`)

   Then the App IDs, with the capabilities each one needs checked at
   registration time (capabilities added later invalidate any profiles
   already issued against the App ID).

   **The macOS profile trap.** The current portal registers every new
   App ID as platform-universal (`iOS, iPadOS, macOS, ...`) and offers
   no platform choice anywhere — not at registration, not in the
   profile flow — and a profile generated through the portal UI
   against a universal App ID comes out **iOS-family only**
   (`Platform: iOS, xrOS, visionOS`, no `OSX`), which a macOS target
   rejects at archive time ("has platforms iOS..., which does not
   match the current platform macOS"). Profiles for macOS targets on
   universal App IDs must instead be minted through the App Store
   Connect API, where the profile type is explicit —
   [`scripts/make-mac-profile.py`](../scripts/make-mac-profile.py)
   does it in one call using the same ASC API key CI uploads with
   (which is why that `.p8` must be kept at hand; see
   [Creating the App Store Connect API key](#creating-the-app-store-connect-api-key)).
   Verify any mac profile before uploading its secret:
   `security cms -D -i <file> | plutil -p - | grep -A6 Platform`
   must list `OSX` — the download's file extension is not a reliable
   signal.

   | App ID | Description | Capabilities |
   |---|---|---|
   | `com.cabalmail.Cabalmail` | `Cabalmail` | **Push Notifications**; **App Groups** (configure → tick `group.com.cabalmail.Cabalmail`); **Associated Domains** (Password AutoFill, see [password-autofill.md](password-autofill.md)) |
   | `com.cabalmail.Cabalmail.NotificationService` | `Cabalmail Notification Service` | **App Groups** (same group). Not Push Notifications — the extension never registers for push itself; it only reads the shared containers |
   | `com.cabalmail.Cabalmail.watchkitapp` | `Cabalmail Watch` | none |
   | `com.cabalmail.CabalmailMac` | `Cabalmail Mac` | **Push Notifications**; **App Groups** (same group); **Associated Domains** |
   | `com.cabalmail.CabalmailMac.NotificationService` | `Cabalmail Mac Notification Service` | **App Groups** (same group), same rationale as the iOS extension |

   Keychain sharing (the app and the extension share a keychain access
   group) needs no portal capability — profiles honor the
   `keychain-access-groups` entitlement for any team-prefixed group
   automatically.

   The APNs **authentication key** that the server's `push_dispatch`
   Lambda signs with is a separate, CI-unrelated credential (Keys →
   **+**, no role, one per team covers every app); see
   [docs/push-notifications.md](push-notifications.md) for
   creating and seeding it.

   CI uses **manual code signing**, so App IDs must exist before you
   create the matching provisioning profiles in the next step.
5. **Create the provisioning profiles** for each App ID. See
   [Creating provisioning profiles](#creating-provisioning-profiles) —
   produces the `IOS_APP_STORE_PROFILE` / `IOS_NSE_APP_STORE_PROFILE` /
   `WATCHOS_APP_STORE_PROFILE` / `MAC_APP_STORE_PROFILE` / (optional)
   `MAC_DEVID_PROFILE` secrets.
6. **Create an App Store Connect API key** with the **App Manager** role. See
   [Creating the App Store Connect API key](#creating-the-app-store-connect-api-key)
   — produces the `APP_STORE_CONNECT_API_KEY_ID` /
   `APP_STORE_CONNECT_API_ISSUER_ID` / `APP_STORE_CONNECT_API_KEY_P8`
   triple.
7. **Create two App Store Connect app records** at
   [appstoreconnect.apple.com](https://appstoreconnect.apple.com) → Apps
   → **+** → New App:

   | Record | Platforms to tick | Bundle ID | Name |
   |---|---|---|---|
   | iOS / iPadOS / visionOS app | iOS ✓, visionOS ✓ | `com.cabalmail.Cabalmail` | Cabalmail |
   | macOS app | macOS ✓ | `com.cabalmail.CabalmailMac` | Cabalmail Mac |

   SKU can be anything (e.g. `cabalmail-ios`, `cabalmail-mac`); it's
   never shown publicly. Primary language English (U.S.) or whichever
   fits.

   The "Cabalmail Mac" name is deliberate: App Store Connect requires
   each record's name to be unique across your account, so the macOS
   app can't reuse the iOS app's "Cabalmail" listing. The mismatch is
   confined to App Store Connect and TestFlight metadata — the
   installed macOS app overrides `CFBundleName` and `PRODUCT_NAME`
   back to `Cabalmail` (see `apple/project.yml`), so the menu bar and
   the `.app` bundle on disk both read "Cabalmail". Don't try to
   rename the App Store Connect record to "Cabalmail" to "fix" the
   apparent inconsistency; Apple will reject the name as conflicting.

   Without these records, CI uploads land in App Store Connect but
   aren't attached to anything visible and you cannot distribute the
   build.
8. **Populate the GitHub secrets** listed in the next section.
9. **Create the TestFlight internal groups CI distributes to.** On
   **each** app record (iOS and macOS), create two internal testing
   groups named exactly **`stage`** and **`prod`** (lowercase — the
   upload jobs look the group up by name):
   - App Store Connect → your app → **TestFlight** tab → **Internal
     Testing** → **+**.
   - Add your Apple ID (with an App Store Connect role) as a tester to
     the groups you want builds offered on.
   - Leave **"Enable automatic distribution" unchecked** in the
     creation dialog. CI attaches each uploaded build to the group
     matching its branch (`stage` pushes → `stage`, `main` → `prod`)
     via the App Store Connect API (`assign-testflight-group.py`), and
     fails the upload job if the attach doesn't succeed. Automatic
     distribution would give every group every build, erasing the
     branch routing — and the API refuses explicit attaches to such
     groups, so the assign step would fail. The explicit attach exists
     to replace it, not to supplement it.
   - The distribution mode is **immutable after creation** — the
     checkbox exists only in the create dialog, and the group Settings
     tab merely displays the resulting "Build Distribution" state. To
     convert an existing automatic group: rename it aside (Settings →
     Edit Name), create a fresh group under the canonical name with the
     checkbox unchecked, re-add the testers, attach the latest build by
     hand so access continues, then delete the renamed group.
   - Install the **TestFlight** app on the target device, sign in, and
     accept the invite.

   Internal groups hold up to 100 team members and do not require Apple
   Beta Review. External groups (invite-by-email, up to 10,000 testers)
   would be the next step before an App Store launch.

## GitHub secrets for CI

`.github/workflows/apple.yml` has four jobs. The `kit-test` and `app-build`
jobs run unsigned (`CODE_SIGNING_ALLOWED=NO`) and require **no** secrets —
PRs from any branch get green CI out of the box.

The `upload-ios` and `upload-mac` jobs sign and push to TestFlight using
**manual code signing**: no `-allowProvisioningUpdates`, no auto-creation of
Development or Distribution certificates from the runner. The archive
grabs the provisioning profile out of a pre-installed file identified by
its UUID. One cost: you register the profile once and supply it as a
secret. One benefit: Apple's per-team certificate cap (2 Development /
3 Distribution) can't fail the build the way it does under
auto-provisioning.

The jobs are gated on the secrets below. `upload-ios` skips cleanly if
any of its required secrets are absent, naming the specific missing
secret(s) in the workflow summary. `upload-mac` **fails** in the same
situation — missing Mac signing secrets on a `main` / `stage` push is
treated as a release regression rather than an opt-in skip. Secrets may
be set at the repository level or per-environment (Settings →
Environments → `stage` / `prod`).

**Required (both jobs):**

| Secret | What it is | Where to get it |
|---|---|---|
| `APPLE_TEAM_ID` | 10-character Apple Developer team ID | [developer.apple.com](https://developer.apple.com/account) → Membership details. If you belong to multiple teams, make sure you're viewing the right one. |
| `APPLE_DISTRIBUTION_CERT_P12` | base64 of your Apple Distribution `.p12` | See [Exporting the distribution certificate](#exporting-the-distribution-certificate) below |
| `APPLE_DISTRIBUTION_CERT_PASSWORD` | Password you set when exporting the `.p12` | GitHub does not accept empty secrets, so the export password must be non-empty |
| `APP_STORE_CONNECT_API_KEY_ID` | ~10-character key ID (e.g. `ABC123DEF4`) | App Store Connect → Users and Access → Integrations → Keys |
| `APP_STORE_CONNECT_API_ISSUER_ID` | UUID shown next to "Issuer ID" on the same page | — |
| `APP_STORE_CONNECT_API_KEY_P8` | base64 of the `.p8` key file | See [Creating the App Store Connect API key](#creating-the-app-store-connect-api-key) below |

**Required (iOS job only):**

| Secret | What it is |
|---|---|
| `IOS_APP_STORE_PROFILE` | base64 of the `.mobileprovision` for `com.cabalmail.Cabalmail` (App Store distribution). See [Creating provisioning profiles](#creating-provisioning-profiles) below. One profile covers both the iOS and visionOS upload legs — modern App Store profiles list both platforms. |
| `WATCHOS_APP_STORE_PROFILE` | base64 of the `.mobileprovision` for `com.cabalmail.Cabalmail.watchkitapp` (App Store distribution). The iOS archive embeds the watch app, so the iOS upload leg skips (with a warning) until this secret exists; the visionOS leg is unaffected. |
| `IOS_NSE_APP_STORE_PROFILE` | base64 of the `.mobileprovision` for `com.cabalmail.Cabalmail.NotificationService` (App Store distribution), the push Notification Service Extension embedded in the iOS archive. Gates **both** the iOS and visionOS upload legs: the push entitlements live on the shared app target, so every leg's archive needs profiles issued against the capability-bearing App ID — this secret doubles as the "push signing assets are ready" sentinel, and both legs skip (with a warning) until it exists. |

**Required (macOS job only):**

| Secret | What it is |
|---|---|
| `MAC_APP_STORE_PROFILE` | base64 of the `.provisionprofile` for `com.cabalmail.CabalmailMac` (App Store distribution). |
| `MAC_NSE_APP_STORE_PROFILE` | base64 of the `.provisionprofile` for `com.cabalmail.CabalmailMac.NotificationService` (App Store distribution), the push Notification Service Extension embedded in the macOS archive. The macOS upload leg skips (with a warning) until this secret exists — it doubles as the "macOS push signing assets are ready" sentinel. |
| `MAC_INSTALLER_CERT_P12` | base64 of a **Mac Installer Distribution** `.p12`. The outer `.pkg` that wraps the macOS `.app` is signed with this cert (distinct from `Apple Distribution`, which signs the `.app` bundle itself). See [Exporting the Mac Installer certificate](#exporting-the-mac-installer-certificate). |
| `MAC_INSTALLER_CERT_PASSWORD` | Password used when exporting the `.p12`. Must be non-empty. |

**Optional (macOS notarized `.app` artifact):**

| Secret | What it is |
|---|---|
| `DEVELOPER_ID_CERT_P12` | base64 of your **Developer ID Application** `.p12` (different cert type from Apple Distribution) |
| `DEVELOPER_ID_CERT_PASSWORD` | Password you set when exporting the `.p12` |
| `MAC_DEVID_PROFILE` | base64 of the `.provisionprofile` for `com.cabalmail.CabalmailMac` (Developer ID distribution). All three Developer-ID secrets (cert + this + the NSE profile below) must be set to produce the notarized artifact; missing any one and the job completes after the TestFlight upload and skips notarization. |
| `MAC_NSE_DEVID_PROFILE` | base64 of the `.provisionprofile` for `com.cabalmail.CabalmailMac.NotificationService` (Developer ID distribution) — the embedded extension needs its own profile under the developer-id export method. |

The App Store Connect API key triple (`KEY_ID` + `ISSUER_ID` + `P8`) is used
for `altool` uploads and macOS `notarytool` submission. Under manual signing
`xcodebuild` itself no longer needs the key at archive time, but the other
callers still do.

See [Creating provisioning profiles](#creating-provisioning-profiles) for
the one-time setup and [Optional: Developer ID certificate for notarized
artifacts](#optional-developer-id-certificate-for-notarized-artifacts) for
the Developer ID flow.

### Exporting the distribution certificate

You need an **Apple Distribution** certificate that belongs to the same team as
`APPLE_TEAM_ID`. A development certificate or a certificate from a different
team will not work for TestFlight.

1. Open **Keychain Access** (⌘+Space → type `Keychain Access`, or Applications
   → Utilities → Keychain Access).
2. In the sidebar, select the **login** keychain and the **My Certificates**
   category.
3. Look for an entry named `Apple Distribution: Your Name (TEAMID)` where
   `TEAMID` matches `APPLE_TEAM_ID`.
   - If you only see `Apple Development: …` or `iPhone Developer: …`, or the
     TEAMID is wrong, you need to create a new one. In Xcode: **Xcode → Settings
     → Accounts**, select your Apple ID and the correct team, click **Manage
     Certificates…**, then **+** → **Apple Distribution**. The new cert lands
     in the login keychain automatically.
4. Right-click the cert → **Export "Apple Distribution…"**, save as `.p12`.
5. When prompted, enter a non-empty password you'll remember (or
   `openssl rand -base64 24 | pbcopy` and keep it on the clipboard).
6. Authenticate with your macOS login password when Keychain asks.
7. Encode and copy:
   ```sh
   base64 -i ~/Desktop/cabalmail-dist.p12 | pbcopy
   ```
   Paste into `APPLE_DISTRIBUTION_CERT_P12`. Put the export password into
   `APPLE_DISTRIBUTION_CERT_PASSWORD`.
8. Delete the `.p12` when done — it contains your private key:
   ```sh
   rm ~/Desktop/cabalmail-dist.p12
   ```

### Exporting the Mac Installer certificate

The Mac App Store wraps every `.app` in a `.pkg`, and Apple requires the
outer `.pkg` to be signed with a separate **Mac Installer Distribution**
certificate (a.k.a. `3rd Party Mac Developer Installer` — Keychain and
portal use different names for the same cert type). Distinct from the
`Apple Distribution` cert used to sign the `.app` itself. Skip this
section if you only ship iOS.

1. **Create the cert** at
   [developer.apple.com → Certificates → + → Mac Installer Distribution](https://developer.apple.com/account/resources/certificates/add):
   - Generate a CSR in Keychain Access (**Keychain Access → Certificate
     Assistant → Request a Certificate From a Certificate Authority…** →
     enter your email, pick **Saved to disk**, **Continue**).
   - Upload the CSR, download the returned `.cer`, double-click it so
     Keychain Access imports it and links it to the private key.
2. **Export from Keychain Access** exactly like the Apple Distribution
   cert — right-click the cert (labelled
   `3rd Party Mac Developer Installer: Your Name (TEAMID)` on modern
   macOS, or `Mac Installer Distribution: …` on older installs —
   functionally identical), **Export "…"**, save as `.p12`, non-empty
   password.
3. **Encode and set the secrets:**
   ```sh
   base64 -i ~/Desktop/cabalmail-installer.p12 | pbcopy
   ```
   Paste into `MAC_INSTALLER_CERT_P12`. Password into
   `MAC_INSTALLER_CERT_PASSWORD`.
4. **Delete the `.p12`:**
   ```sh
   rm ~/Desktop/cabalmail-installer.p12
   ```

### Creating provisioning profiles

CI signs every archive with a provisioning profile you created ahead of
time. Three profiles are needed at most — iOS App Store, macOS App Store,
macOS Developer ID — and each lives in App Store Connect referencing the
distribution cert you just exported. Recreate them whenever the cert rolls
(typically once a year); otherwise nothing to do.

1. **Register the App Group and App IDs** (one-time) at
   [developer.apple.com → Identifiers](https://developer.apple.com/account/resources/identifiers/list)
   → **+**, if you haven't already — with the capabilities listed in
   step 4 of [Signing prerequisites](#signing-prerequisites):
   - App Group `group.com.cabalmail.Cabalmail`
   - `com.cabalmail.Cabalmail` (App IDs → iOS, tvOS, watchOS, visionOS)
     — Push Notifications + App Groups + Associated Domains
   - `com.cabalmail.Cabalmail.NotificationService` (App IDs → iOS, tvOS,
     watchOS, visionOS) — App Groups only; the push Notification Service
     Extension embedded in the iOS archive
   - `com.cabalmail.Cabalmail.watchkitapp` (App IDs → iOS, tvOS, watchOS,
     visionOS) — the embedded watch companion app
   - `com.cabalmail.CabalmailMac` — Push Notifications + App Groups +
     Associated Domains
   - `com.cabalmail.CabalmailMac.NotificationService` — App Groups
     only; the push Notification Service Extension embedded in the
     macOS archive

   For the two Mac App IDs, create the profiles with
   [`scripts/make-mac-profile.py`](../scripts/make-mac-profile.py)
   rather than the portal UI — the portal cannot produce a
   macOS-platform profile for a universal App ID (see the macOS
   profile trap in [Signing prerequisites](#signing-prerequisites)),
   e.g.:

   ```sh
   ASC_KEY_ID=... ASC_ISSUER_ID=... ASC_KEY_P8=~/keys/AuthKey_....p8 \
   python3 scripts/make-mac-profile.py \
     com.cabalmail.CabalmailMac.NotificationService \
     "Cabalmail macOS NSE App Store"
   ```

   The script writes the `.provisionprofile`, prints the exact base64
   for the GitHub secret, and names the `security cms` platform check
   to run first. API-minted profiles appear in the portal's Profiles
   list afterwards and are manageable there like any other.

   Capabilities must be on the App ID **before** its profiles are
   created: editing an App ID's capabilities flips every existing
   profile for it to **Invalid**, and each must then be re-issued
   (click the profile → Edit → Save/Generate → Download) and its
   GitHub secret refreshed. Profiles for *other* App IDs are
   unaffected.

2. **Create the profiles** at
   [developer.apple.com → Profiles](https://developer.apple.com/account/resources/profiles/list)
   → **+**:

   | Profile | Distribution type | App ID | Certificate | Filename extension |
   |---|---|---|---|---|
   | Cabalmail iOS App Store | App Store | `com.cabalmail.Cabalmail` | Apple Distribution | `.mobileprovision` |
   | Cabalmail NSE App Store | App Store | `com.cabalmail.Cabalmail.NotificationService` | Apple Distribution | `.mobileprovision` |
   | Cabalmail Watch App Store | App Store | `com.cabalmail.Cabalmail.watchkitapp` | Apple Distribution | `.mobileprovision` |
   | Cabalmail macOS App Store | App Store | `com.cabalmail.CabalmailMac` | Apple Distribution | `.provisionprofile` |
   | Cabalmail macOS NSE App Store | App Store | `com.cabalmail.CabalmailMac.NotificationService` | Apple Distribution | `.provisionprofile` |
   | Cabalmail macOS Developer ID *(optional)* | Developer ID | `com.cabalmail.CabalmailMac` | Developer ID Application | `.provisionprofile` |
   | Cabalmail macOS NSE Developer ID *(optional)* | Developer ID | `com.cabalmail.CabalmailMac.NotificationService` | Developer ID Application | `.provisionprofile` |

   Profile names are arbitrary — CI matches by the UUID embedded in the
   file, not the name. All profiles share the same Apple Distribution
   certificate. Create the four macOS rows with
   `scripts/make-mac-profile.py` (pass `MAC_APP_DIRECT` as the third
   argument for the Developer ID variants), not the portal UI — see
   the macOS profile trap above.

3. **Download each profile** (click the profile → **Download**; the
   script already wrote the mac ones locally and printed their base64).

4. **Base64-encode each** and paste into the matching GitHub secret:
   ```sh
   base64 -i "Cabalmail_iOS_App_Store.mobileprovision" | tr -d '\n' | pbcopy
   ```
   | Downloaded file | GitHub secret |
   |---|---|
   | iOS `.mobileprovision` | `IOS_APP_STORE_PROFILE` |
   | NSE `.mobileprovision` | `IOS_NSE_APP_STORE_PROFILE` |
   | Watch `.mobileprovision` | `WATCHOS_APP_STORE_PROFILE` |
   | macOS App Store `.provisionprofile` | `MAC_APP_STORE_PROFILE` |
   | macOS NSE App Store `.provisionprofile` | `MAC_NSE_APP_STORE_PROFILE` |
   | macOS Developer ID `.provisionprofile` | `MAC_DEVID_PROFILE` |
   | macOS NSE Developer ID `.provisionprofile` | `MAC_NSE_DEVID_PROFILE` |

   Stray whitespace — a trailing newline from the paste, or a `base64`
   build that wraps its output — is harmless: the workflow strips all
   whitespace before decoding, and the very next step fails loudly if
   the decoded bytes aren't a valid signed profile.

5. **Delete the downloaded files** — they embed the team's distribution
   cert public key and the App ID's capabilities, and can be re-created
   from the portal if you need them again.

### Creating the App Store Connect API key

1. App Store Connect → **Users and Access** → **Integrations** tab → **Keys**.
2. Click the **+** to generate a new key.
3. Name it something descriptive (e.g. `Cabalmail CI`). Role: **App Manager**.
   App Manager covers everything CI needs — TestFlight upload,
   notarization, and the profile-creation API that
   `scripts/make-mac-profile.py` calls to mint macOS profiles.
   **Keep the downloaded `.p8` somewhere durable** (a password
   manager, not just the GitHub secret): Apple only lets you download
   it once, and you will need it locally again every time a macOS
   profile has to be re-minted — capability changes invalidate
   profiles, and the portal UI cannot recreate the macOS ones.
4. Copy the **Issuer ID** (top of the page) → `APP_STORE_CONNECT_API_ISSUER_ID`.
5. Copy the **Key ID** (shown in the row for the new key) →
   `APP_STORE_CONNECT_API_KEY_ID`.
6. Click **Download API Key**. **This is your only chance** — if you close the
   page without downloading, you have to revoke the key and create a new one.
7. Encode and copy. Use `tr -d '\n'` to strip the line wrapping macOS's
   `base64` adds at 76 chars; GitHub secrets can mangle whitespace in
   multiline values and CI's decode step is stricter as a result:
   ```sh
   base64 -i AuthKey_XXXXXXXXXX.p8 | tr -d '\n' | pbcopy
   ```
   Paste into `APP_STORE_CONNECT_API_KEY_P8`.
8. Delete the `.p8` — it grants broad write access to your App Store Connect
   account:
   ```sh
   rm AuthKey_XXXXXXXXXX.p8
   ```

### Optional: Developer ID certificate for notarized artifacts

Only needed if you want `upload-mac` to produce a notarized `.app.zip`
workflow artifact for distribution outside the App Store / TestFlight.
Without these secrets, `upload-mac` completes successfully after the
TestFlight upload and skips the notarization steps.

1. Xcode → Settings → Accounts → select your Apple ID and team →
   Manage Certificates… → **+ → Developer ID Application**. (This is a
   different cert type from Apple Distribution — you need both.)
2. Export the new certificate from Keychain Access the same way as the
   distribution cert (see [Exporting the distribution
   certificate](#exporting-the-distribution-certificate)), set a
   non-empty password, encode with `base64 -i cert.p12 | tr -d '\n' |
   pbcopy`.
3. Set `DEVELOPER_ID_CERT_P12` and `DEVELOPER_ID_CERT_PASSWORD`.

## CI workflow

`.github/workflows/apple.yml` has four jobs:

| Job | Runs when | What it does |
|---|---|---|
| `kit-test` | Any push touching `apple/**` or the workflow file | SwiftLint + `xcodebuild test` on the CabalmailKit package (scheme `CabalmailKit-Package`) across macOS / iOS / visionOS destinations |
| `app-build` | Same | Unsigned `xcodebuild build` for `Cabalmail` (iOS) and `CabalmailMac` (macOS) |
| `upload-ios` | Pushes to `main` or `stage`, with the seven signing secrets configured | Manual-signed archive → TestFlight upload → attach to the branch's internal test group |
| `upload-mac` | Same | Manual-signed App Store `.pkg` → TestFlight upload, plus (optional) a Developer ID export → `notarytool submit --wait` → `stapler staple` → uploaded as a workflow artifact → attach to the branch's internal test group |

`upload-ios` gracefully no-ops (with a workflow warning) when its
required secrets are missing. `upload-mac` fails the workflow in the
same situation — treat a missing Mac signing secret as a release-blocking
bug. Build and test jobs never require secrets.

Manual signing installs a pre-created provisioning profile from a GitHub
secret via `.github/actions/install-provisioning-profile` (a small
composite action) and passes the profile's UUID to `xcodebuild` as
`PROVISIONING_PROFILE_SPECIFIER`. No `-allowProvisioningUpdates`, no
auto-provisioning, no Apple Development cert creation from the runner.
See the [GitHub secrets for CI](#github-secrets-for-ci) section above for
how to supply each profile.

Pinned Xcode version lives in the `XCODE_VERSION` env var at the top of the
workflow; bump it in lockstep with the deployment targets in `project.yml`
and `CabalmailKit/Package.swift`.

## Installing a build from TestFlight

After a successful CI upload and App Store Connect processing (5–30 min),
the build appears in your app's **Builds** list, and the upload job
attaches it to the internal group matching the branch it was built from
(`stage` pushes → the `stage` group, `main` → `prod`) — see the group
setup in [Apple Developer account setup](#apple-developer-account-setup).
To install one:

1. On your device, install the **TestFlight** app from the App Store.
2. Sign in with the Apple ID that is a member of the group and accept
   the invite from the TestFlight inbox. The build installs like any
   App Store app, with a small yellow dot marking it as a beta.

macOS follows the same flow using the macOS TestFlight app (install
from the Mac App Store). If a build you expected never shows up, check
the upload job's **Assign build to TestFlight group** step — it fails
(with the build number in the error) when the build could not be
attached, and the fallback is attaching that build by hand from the
group's **Builds** tab.

## Setting Cabalmail as the default mail handler

Cabalmail registers as a `mailto:` handler on both iOS and macOS, but
selecting it as the system default is a one-time user action — the OS
does not let an app elect itself.

**macOS** works out of the box. Register the scheme (already done by
`CFBundleURLTypes` in `project.yml`) and the app shows up in System
Settings → Desktop & Dock → Default mail reader; pick Cabalmail and
`mailto:` clicks across the system route here.

**iOS / iPadOS** gates default-mail-app candidacy behind the
`com.apple.developer.mail-client` entitlement, which Apple approves
case-by-case. Until the entitlement is granted, the app will *not*
appear in Settings → Apps → Mail → Default Mail App, even though
`CFBundleURLTypes` is registered. To enable it:

1. Submit the default-app entitlement request via Apple's web form
   at <https://developer.apple.com/contact/request/default-mail-client>
   (the form replaced the older `default-app-requests@apple.com`
   address). The form asks the submitter to confirm, among other
   things, that:
   - the app specifies the `mailto:` scheme in its `Info.plist`,
   - the app can send a message to any valid email recipient,
   - invoking the `mailto:` handler opens a new compose view with
     the To: address set to the target of the URL,
   - the app can receive a message from any email sender.

   All four are true of Cabalmail today; the wiring is in place and
   the unit tests in `CabalmailKit/Tests/CabalmailKitTests/MailtoURLTests.swift`
   cover the parser. Apple reviews and grants the entitlement
   against your team.
2. After approval, enable the **Default Mail App** capability on the
   `com.cabalmail.Cabalmail` App ID (Identifiers → the App ID →
   Capabilities). Editing the capabilities flips the App ID's
   existing profiles to Invalid, so re-issue the iOS App Store
   profile and refresh the `IOS_APP_STORE_PROFILE` secret — see
   [Creating provisioning profiles](#creating-provisioning-profiles).
3. `apple/Cabalmail/Cabalmail.entitlements` (wired into the iOS
   target's `CODE_SIGN_ENTITLEMENTS` via `project.yml`) carries the
   matching key:

   ```xml
   <key>com.apple.developer.mail-client</key>
   <true/>
   ```

   Signed archives fail while the provisioning profile lacks the
   entitlement, so a fork must remove this key until its own request
   is approved and the profile regenerated.

4. Ship a new TestFlight build against the updated profile.

Apple's rules forbid combining `com.apple.developer.mail-client` with
`com.apple.developer.web-browser` in the same app — pick one.

Once the entitlement lands and the user picks Cabalmail in Settings,
`mailto:` clicks in Safari and other apps open Cabalmail with a
compose window pre-filled from the URL's recipients, subject, and
body. Only the standard RFC 6068 hfields (`to`, `cc`, `bcc`,
`subject`, `body`) are honored; other headers are dropped.

### Default-app request: cover-letter template

The web form's free-text box asks for "additional information and test
credentials to confirm that your app meets the mail client criteria."
Before submitting, provision a fresh Cabalmail account on the
deployment the TestFlight build points at, then paste the text below
into the form with the bracketed placeholders filled in. Rotate the
password (or delete the account) after Apple completes review.

```
Cabalmail is a self-hosted native email system for iOS, iPadOS,
visionOS, and macOS. The app is a real mail client: composes traverse
open-Internet SMTP via the operator's own SMTP-OUT relay with DKIM
signing, and inbound mail is delivered through standard SMTP-IN +
IMAP. There is no proprietary transport. Source code, including the
mailto: handler and parser, is public at
https://github.com/cabalmail/cabal-infra (see apple/CabalmailUI/
Shell/AppRootLifecycle.swift and apple/CabalmailKit/Sources/
CabalmailKit/Compose/MailtoURL.swift).

Test credentials for the deployment this TestFlight build is built
against:

  Control domain:  [example.cabalmail.com]
  Username:        [apple-review]
  Password:        [<one-time-password>]
  Test address:    [apple-review@mail.example.cabalmail.com]

The build prompts for the control domain on first launch. Sign in
with the credentials above; the message list opens to the test
account's Inbox.

Verifying each criterion:

1. mailto: in Info.plist. The shipped IPA's Info.plist contains
   CFBundleURLTypes with scheme "mailto" and role "Editor". This is
   generated from apple/project.yml.

2. Sends to any valid recipient. From the message list, tap the
   compose button. Pick a From address from the picker (an initial
   address is auto-provisioned at signup; "Create new address..."
   makes more). Enter any external email address in To, then send.
   Delivery to Gmail, iCloud, and Outlook has been verified in
   production.

3. mailto: handler opens compose with To: pre-filled. The
   .onOpenURL handler parses incoming URLs with the RFC 6068 parser
   covered by MailtoURLTests.swift and routes the result to compose.
   The macOS sibling target shares the same wiring and has been
   verified end-to-end — clicking mailto:test@example.com?subject=Hi
   &body=Hello in Safari opens compose with all three fields
   pre-filled. iOS uses the same SwiftUI .onOpenURL modifier on the
   same handler.

4. Receives mail from any sender. Send a test message from any
   external account to the test address above; it lands in the
   account's Inbox within seconds. The SMTP-IN tier applies spam
   filtering but no sender allowlist.
```

References:
- [Default Mail Client entitlement request form](https://developer.apple.com/contact/request/default-mail-client)
- [`com.apple.developer.mail-client`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.mail-client)
- [Apple Developer forum thread on the approval flow](https://developer.apple.com/forums/thread/650300)

## App icons

Real Cabalmail artwork is installed for every target, all of it generated
from the single source vector at
[`vector/cabalmail-logo.svg`](../vector/cabalmail-logo.svg) by
[`scripts/generate-logo-assets`](../scripts/generate-logo-assets). Nothing
is hand-edited — edit the vector and regenerate. See
[`vector/README.md`](../vector/README.md) for the full spec (geometry,
color tokens, placement transform, per-platform do-not list).

```
apple/Cabalmail/AppIcon.icon/           (iOS / iPadOS — Liquid Glass)
apple/CabalmailMac/AppIcon.icon/        (macOS — Liquid Glass)
  icon.json                Default = forest glyph on cream, Dark = parchment
                           glyph on ink; one ink-glyph template recolored per
                           appearance, on a specialized background gradient.
  Assets/Mark.svg          the glyph template.
apple/Cabalmail/Assets.xcassets/AppIconVision.solidimagestack/
  Back / Middle / Front layers  (1024×1024; opaque cream plate, forest
                           C-disc, forest-deep M — composited with parallax)
apple/CabalmailWatch/Assets.xcassets/AppIcon.appiconset/
  AppIcon-watch.png        (single 1024 slot; watchOS masks it itself)
```

The square icon (iOS / iPadOS / macOS) is an Icon Composer `.icon` bundle,
not an asset-catalog appiconset. This is the **only** format that carries a
per-appearance **macOS** icon: an asset catalog's `luminosity` appearances
are silently dropped by `actool` for the `mac` idiom (they compile to a
legacy, appearance-blind `.icns`), which is why the macOS icon used to
ignore the Dark setting. `actool` still emits the older prerendered
fallbacks from the same `.icon` (`.icns` on macOS, `AppIcon60x60`/`76x76`
on iOS), so the macOS-15 / iOS-18 deployment floors keep a valid icon while
26+ gets the Liquid Glass rendering with Default/Dark (and system-synthesized
Tinted/Clear). Layer-level `fill-specializations` are ignored by the
renderer, so the bespoke dark glyph is expressed as two overlaid glyph
layers (forest on top, hidden in Dark; parchment beneath) rather than one
recolored layer.

All icons pass `xcrun actool` cleanly, and the three build destinations
(iphoneos, macosx, xros) archive with the correct primary icon.

### Regenerating

```sh
make logo            # or: ./scripts/generate-logo-assets
```

One command regenerates every derivative (both Apple catalogs, the React
client, the docs images, the front-door favicon) idempotently. The generator
uses a version-pinned resvg + oxipng, so output is byte-identical across
macOS and CI. Do **not** apply a squircle mask, bake a drop-shadow, or
grayscale the tinted variant — iOS / macOS / visionOS each own those at
runtime.

### visionOS uses the layered `AppIconVision.solidimagestack`

The `Cabalmail` target's visionOS destination is served by a layered
`AppIconVision.solidimagestack` (back / middle / front layers, composited
with parallax on gaze focus), wired via a per-SDK icon-name override in
`project.yml`:

```yaml
"ASSETCATALOG_COMPILER_APPICON_NAME[sdk=xros*]": AppIconVision
```

iOS / iPadOS and macOS use the shared `AppIcon.icon` instead; visionOS is
the one square-icon holdout on the layered stack. The back plate is a
fully-opaque 1024 bitmap (actool rejects a transparent back layer); the
system applies the circular mask. Validating the parallax depth effect
still requires a visionOS device in the loop.

## Architecture

### macOS: native target (not Mac Catalyst)

The roadmap treats macOS as a first-class platform, so the macOS target
is native rather than Mac Catalyst. `CabalmailMac/` is a separate app
target with its own `@main`, menu commands, windows, settings, asset
catalog and entitlements. Everything it shares with the iOS app comes
from the `CabalmailUI` module (below), whose views and view models branch
with `#if os(macOS)` where the platforms diverge.

### Shared app layer: the `CabalmailUI` module

`apple/CabalmailUI/` holds the app layer the iOS / iPadOS / visionOS and
macOS apps have in common: every view, view model and piece of app state.
It is a static library target in `apple/project.yml`, compiled once per
platform as the Swift module `CabalmailUI`, and it inherits the project's
`SWIFT_STRICT_CONCURRENCY: complete`. Membership is the folder: a new
file anywhere under `CabalmailUI/` is in both apps with no `project.yml`
edit.

What stays in the app targets is what only one platform has:
`Cabalmail/` keeps the iOS `@main` (`CabalmailApp.swift`), the App
Intents (Siri and Shortcuts read intent metadata from the app's own
binary, so they cannot live in a library), the Info.plist, the
entitlements and the asset catalogs; `CabalmailMac/` keeps the macOS
`@main`, the menu bar, the Settings window and the menu-bar extra. The
shared session lifecycle reaches the App Intents through
`AppIntentsSessionHooks`, which `CabalmailApp` installs at launch.

Rules that keep the module working:

- **Anything an app target uses from `CabalmailUI` is `public`**: the
  type, the initializer it calls, and each member it reads. Everything
  else stays `internal`, and the test bundles reach it through
  `@testable import CabalmailUI`.
- **One copy of each module per process.** The two apps link the library
  and `-force_load` it, so every object file reaches the app as it would
  if the sources were compiled there, including protocol conformances
  that nothing names by symbol (Swift looks those up at run time, and an
  archive member nothing references is otherwise left out). `CabalmailUI`
  imports CabalmailKit and CabalmailShared without linking them, and
  `CabalmailMacTests` and `CabalmailiOSTests` depend on `CabalmailUI` and
  CabalmailShared with `link: false`: the host app carries every one of
  these modules (CabalmailShared inside the Kit), and a second copy
  splits their types (`as? CabalmailError` casts fail). Any new target
  that links the library needs the same `-force_load`.
- **Asset catalogs stay in the app targets.** A static library carries no
  resources. Shared code looks assets up by name (`Image("CabalmailMark")`
  resolves against the app bundle) rather than through generated asset
  symbols, which exist only in the app modules.
- **Two files are also compiled by path into the watch app**, which does
  not link the library: `Platform/HostPlatform.swift` and
  `Platform/ConfirmationDialogPolicy.swift`. Moving one means updating
  its path in `project.yml`, and neither may import `CabalmailUI`. The
  stores the Safari web extensions read are not compiled by path: they
  live in the `CabalmailShared` module (see "Extension-shared values"
  below), which both Safari appexes link.
- **The Safari appex folders keep their historical names.** The native
  handler both Safari appexes compile,
  `SafariWebExtensionHandler.swift`, lives in
  `apple/CabalmailMacWebExtension/` despite the name, and
  `apple/CabalmailWebExtension/` holds only the iOS appex's `Info.plist`
  and entitlements. Renaming them touches the source, `Info.plist` and
  entitlement paths in `project.yml`, `.swiftlint.yml`'s folder list and
  the changelog gate's folder list for no change in behaviour, so it waits for XcodeGen target
  templates, which a future extension would bring.

The module is sorted into feature folders, at most two levels deep.
Loose files in a feature folder are shared by that feature's subfolders.

| Folder | What lives there |
| --- | --- |
| `App/` | `AppState` and all of its extension files, and the app-level types it holds: the toast, the signed-out reason, the drag-and-drop move request. `AppState` holds the commands and menus, compose hand-off, drag and drop, contacts, BIMI and `mailStore`; its session surface (`status`, `client`, `navCoordinator`, sign-in and sign-out) forwards to its `SessionManager` |
| `Session/` | The session lifecycle, in `SessionManager`: sign-in and its second factor, restoring the last session, signing out and its ordering (`SessionTeardownGate`), the session's client, cursor, preferences sync and expiry observer, the Inbox badge and feed pollers (`SessionPollers`), and lending the client to the push and App Intents paths (`borrowClient()`, one client per account). `SessionEnvironment` and `SessionHooks` are its seams to the outside; `SessionOwnerHooks` are what a session does to `AppState`'s state. Also the sign-in screen and its error wording |
| `Navigation/` | Each main window's `SceneNavigator` (its `AppRoute`, landing, search model, its folder list's selection, and the hand-off to a tree a layout swap rebuilds, which takes a multi-selection along), with the feed reader's `FeedNavigationState` and the `TreeGate` both use, and the window's `WindowRestores` (the message, reading position and feed item its lists and reader take once ready); `NavStateCoordinator` (the per-install resume session, reading positions and the cross-device cursor) and Spotlight routing |
| `Commands/` | The Message, Mailbox and Feeds menu commands, when each is enabled, and which window it acts on |
| `Shell/` | How a window is laid out: the sign-in / signed-in router, the iPhone tab bar, the iPad and Mac split view (`MailRootView`), the Vision Pro tabs, the layout and column policies, the per-window theme, and the main window root's launch and lifecycle chain both app entries apply (`appRootLifecycle`) |
| `Shell/Columns/` | Column and inspector widths, the column resize handle, the macOS split-view autosave workaround |
| `Mail/` | Mail pieces used by more than one mail column: drag and drop, Move to Folder, the sender avatar, the authentication line |
| `Mail/Store/` | Mail state the folder list, message list, reader and composer share: `MailSessionStore`, which `AppState` owns as `mailStore` and resets at sign-out, made of `MailCounts` (folder counts: the unread ones are the sidebar badges and a message list's Unread pill, the flagged ones its Flagged pill; and the Inbox count behind the app badge), `MessageShields` (the one record of writes in flight and removals just confirmed, which every list's merge and every writer of a fetched STATUS asks, so a refresh can't undo a write made anywhere or count it twice), `MailEvents` (every change to mail, delivered at once and in order to every message list's and reader's view model but the one that made it, naming the window that started it when a reader did, and saying whether another list's selection may move on), and `MailMutationService` (the one place the app's writes go through: every flag change, move, dispose and purge from a list, the reader or the composer is recorded, posted and counted before it goes out, made through the writer's client, then confirmed, forgetting a removed message in the offline caches, or taken back; Mark All as Read and Empty Trash go through it too, acting once the server answers; a notification's actions are the exception, #1973); and `FolderPollers` (the change watching of the folders open in message lists: one `FolderPoller` per folder, made by the first list showing it and stopped with the last or at sign-out, whose watcher events and 60-second tick each ask one STATUS that every list on the folder takes); also saved folder counts |
| `Mail/Folders/` | The folder sidebar and its view model, filters, rows, New Folder |
| `Mail/MessageList/` | `MessageListView`, `MessageListViewModel` and their extension files: rows, swipes, selection, bulk actions, sort, the folder-switch menu; `FolderWindowLoader`, a folder list's window (rows, positions, paging, refresh; the search surface has none), with its engines `WindowPager`, `WindowRefresher`, `WindowReconciler` and `WindowSnapshot`, and the value types `EnvelopeOrder` and `WindowPlanner` |
| `Mail/Reader/` | `MessageDetailView`, `MessageDetailViewModel` and their extension files: the header, the toolbar and its policies, attachments, calendar invites, View Source |
| `Mail/Search/` | `MailSearchSession`, a list's search (query, filters, results and their paging), the search model and query, the Search tab, the global search field, the filters sheet, and the list's `+Search` extension files |
| `Feeds/` | The Feeds tab root, `FeedStoreChanges` (how the feed sidebar, item list and reader follow `RssStore.changes()`, each from its view's `.task` through its model's `observe()`), feed health and per-feed web storage |
| `Feeds/Sidebar/`, `Feeds/ItemList/`, `Feeds/Reader/`, `Feeds/Management/` | The feed tree, the item list, the item reader, and subscribing, editing and OPML |
| `Compose/` | `ComposeView`, `ComposeViewModel`, the From picker, drafts and the failed-send banner |
| `Compose/Recipients/`, `Compose/Editor/`, `Compose/Windows/` | The To / Cc / Bcc fields and contacts picker; the rich-text editor; how a composer opens and closes (router, slot registry, scene) |
| `Addresses/` | The address list, its view model, New Address, address titles in menus |
| `Rules/` | The rule list, the rule editor and its view model |
| `Settings/` | The Settings screens, the iPad Settings sheet, preference sync |
| `Shared/Chrome/` | Feature-neutral chrome: the filter pill every pill row draws (`FilterPill`, and `FilterPillStrip`, which stacks pills in a narrow column), the sidebar count badge (`CountBadge`, which draws `FolderCountBadge`'s rule on folder and feed rows alike), the sidebar tree row (`SidebarTreeRowLabel`, which indents, discloses and tints mail folders and feeds by `FolderIconTint` and `FolderNameTint`), sidebar header and filter rows, the list title menus' shared rows and hosts (`TitleSwitchMenu.swift`), toolbar priority, the reader toolbar's budgets and placement for both readers (`ReaderToolbarPolicy`; each reader's action lists stay with it, in `ReaderToolbarLayout` and `FeedReaderToolbarLayout`), branding |
| `Shared/Primitives/` | Generic building blocks: the load-state scaffold, the flow layout, a list's selection (`SelectionModel`: the rows picked, Select mode, and the anchor and cursor a range selection works from) |
| `Shared/BodyRendering/` | Rendering a message or article body for both readers: the HTML view and its bridges, HTML rewriting, plain text, the link menu |
| `Shared/Banners/` | Toasts and where banners sit |
| `Platform/` | Small per-OS adapters: host platform, confirmation-dialog roles, the pasteboard |
| `Platform/Services/` | Push (the app delegate and `PushRegistrar`) and the watch hand-off |

A file belongs in `Shared/` only if it knows nothing about any one
feature, or if several features use it without carrying one feature's
logic; otherwise it stays with its feature. Platform conditionals
(`#if os`) are still spread through the feature folders; new
layout-level branches belong in `Shell/` and new OS adapters in
`Platform/`.

### Extension-shared values: the `CabalmailShared` module

The app extensions don't link CabalmailKit, which keeps them small and
keeps the Kit's resource bundle out of them. What an extension and the
app must spell identically lives instead in `CabalmailShared`, a second
library product of the `CabalmailKit` package
(`apple/CabalmailKit/Sources/CabalmailShared/`):

- `AppGroup.identifier`, the App Group whose `UserDefaults` suite the
  apps write and the extensions read.
- `ExtensionControlDomainStore` and `PrivateLinkTokenStore`, the two
  stores the Safari web extensions' native handler reads: the control
  domain the app signed in to, and the private-link token rows (#1765).
  The app writes both. `extensions/shared/test/privateLink.test.ts` reads
  the token store's source by path to check its token alphabet, and
  `extensions.yml` runs that test on a pull request that changes the
  file, so a move updates both paths.
- `PushHandoff` and `PushTokenPayload`: where the app leaves the API URL
  and the Cognito ID token for the notification service extensions (the
  defaults key, the keychain service, account and access-group suffix),
  and the JSON the token is stored as. `PushEnrichmentStore` writes them;
  `CabalmailNotificationService/NotificationService.swift` reads them.
- `PushMessageCoordinates` and `PushEnvelope`, the two push wire formats:
  the payload's `msgRef` (folder, uid hint and `msg_id`; a uid of 0 or an
  empty `msg_id` reads as none), which is also the `/push_envelope`
  request body, and that endpoint's reply. The notification extension
  parses, sends and patches with them; the Kit's `fetchPushEnvelope`
  sends and decodes with them; the app's `PushMessageRef` parses through
  them and the macOS in-app enrichment writes with them.

How it is linked:

- **The Kit depends on it**, so the apps and the watch get it inside the
  Kit and link nothing new.
- **The two notification service extensions and the two Safari web
  extensions link the `CabalmailShared` product** and import it, never
  the Kit. It is a static product with no
  resources, so its code lands in each extension's own binary and
  nothing new is embedded or signed.
- **Keep it Foundation only**, with no resources, no logging (the
  `os.Logger` lint rule exempts only `CabalmailLog` and the notification
  extension) and no UI imports, and leave its product type automatic. A
  resource would add a bundle to every extension, and a dynamic product
  would put a framework inside each `.appex`, which App Store upload
  rejects.
- **Entitlements keep their literals**, since a plist can't import a
  module: the App Group is in six entitlements files and the keychain
  group in four (both apps and both notification extensions). No test
  reads them, so change them by hand with the module.
  `PushHandoffContractTests` pins each Swift constant to the shipped
  value, so a change on the code side fails the Kit tests instead of
  quietly turning every enriched notification back into "New mail".
- **The Kit's xcodebuild test scheme is `CabalmailKit-Package`.** With two
  library products, Xcode gives only that scheme a test action, so
  `apple.yml` and `scripts/build-apple.sh` run
  `xcodebuild test -scheme CabalmailKit-Package` from
  `apple/CabalmailKit`. `swift test` is unaffected.

### Runtime configuration: published `config.json`

The React app loads runtime configuration from `/config.js` on CloudFront.
`config.js`'s body happens to be valid JSON, so Terraform also writes a
sibling `config.json` object from the same template variables (see
[`terraform/infra/modules/app/s3.tf`](../terraform/infra/modules/app/s3.tf)).

The Apple client fetches `https://{control_domain}/config.json` on first
launch and caches it in `UserDefaults`. The same IPA works against
dev/stage/prod by pointing at a different control domain — only the
bootstrap URL differs. The schema is modelled by
`CabalmailKit.Configuration`.

### Cognito: hand-rolled `USER_PASSWORD_AUTH`

The Cognito pool is provisioned with `explicit_auth_flows =
["USER_PASSWORD_AUTH"]` (see
[`terraform/infra/modules/user_pool/main.tf`](../terraform/infra/modules/user_pool/main.tf)),
so the wire surface reduces to JSON POSTs against
`https://cognito-idp.<region>.amazonaws.com/`. `CognitoAuthService` drives
that directly — no AWS SDK dependency, no ~2 MB extra binary. The
`AuthService` protocol leaves room to swap in Amplify later.

### Mail traffic: the Lambda API, not IMAP or SMTP

`CabalmailKit` speaks no mail protocol. `ApiBackedImapClient` adapts the
same Lambda endpoints the React app uses (`/list_folders`,
`/list_envelopes`, `/fetch_message`, `/set_flag`, `/move_messages`, ...)
onto the `ImapClient` protocol, and `CabalmailClient.send(_:)` posts to
`/send`, which does the Outbox append, SMTP submission and Sent move
server-side. Issue #371 made the switch after the earlier hand-rolled
`NWConnection` IMAP and SMTP clients proved unreliable across network
transitions and sleep/wake; that stack has since been deleted.

### API errors: what a failed request throws

Every Kit API request throws `CabalmailError`, with one deliberate
exception: a lost `/set_rules` race throws `RuleSetConflictError`. (A
Cognito 2xx that isn't JSON still escapes as a Foundation error, #1902.)
The user-facing copy for every case is the enum's `LocalizedError`
conformance in `Models/Errors.swift`. Most views show
`error.localizedDescription`; some word particular cases themselves,
among them the sign-in form (`SignInErrorText`), the composer
(`ComposeViewModel.describe`), Siri (`IntentError`), the feed views
(`FeedErrorText`) and the message list's bulk actions.

- **The Lambda API or S3 said no: `.http(status:body:)`.** Any non-2xx
  from the Lambda API, or from a presigned S3 URL, that the next two
  bullets don't cover, with `body` the reply as text. Its copy is the
  body's `status` string, or its `message` string when there is no
  `status`, if that string is more than one word: a one-word `status`
  such as `unable` doesn't fall through to `message`, and a handler's
  `{"Error": ...}` body isn't read (#1918). Otherwise it is "The server
  couldn't complete that request (NNN)." The callers that act on a
  particular failure compare the status: a 409 `duplicate_in_flight` from
  `/send` becomes `.sendInFlight`, a 409 from `/set_rules` becomes
  `RuleSetConflictError`, and a 400 from `/fetch_bimi` is cached as "no
  logo".
- **A failure carrying a code: `.server(code:message:)`.** Three sources
  produce it: the RSS API's error tokens (`not_a_feed`,
  `needs_credentials`, ...), which `FeedErrorText` maps to copy; Cognito's
  exception names (`NotAuthorizedException` is `.invalidCredentials` or
  `.authExpired` instead, and an unreadable reply gets the code
  `Unknown`); and the `config.json` fetch, with its HTTP status as the
  code. Some views show `.server`'s message as written: Siri, the feed
  views for a token they have no copy for, and the sign-in form (bare for
  a Cognito trigger's copy, after "Server error:" otherwise; a mistyped
  second-factor code gets its own sentence). An RSS token carries the
  reply's `Error` sentence and every other Lambda API failure is `.http`,
  so none of them shows a raw Lambda API reply.
- **Two Lambda API statuses are handled first.** A 401 forces a token
  refresh (one shared by a burst of 401s) and replays the request once; a
  401 on the replay announces the session's expiry and throws
  `.authExpired`. A 503 with `{"status": "maintenance"}` is
  `.maintenance(message:)`, whose message is shown as written. A
  presigned S3 URL gets neither: its 401 or 503 is plain `.http`.
- **A 2xx that didn't parse: `.decoding`.** Every strict decode of a
  Lambda API reply, the RSS endpoints included, goes through
  `URLSessionApiClient.decodeReply`, which names the endpoint
  ("list_envelopes returned an unexpected reply") and writes where the
  decode stopped (its kind and coding path, never a field's value) to
  `CabalmailLog`. A few
  reads are lenient on purpose and fall back instead. The `config.json`
  fetch and the Cognito calls decode on their own paths. A URL the API
  hands back for the client to fetch (the presigned message, attachment,
  inline-image and upload URLs, and the BIMI logo) is followed only when
  it is absolute `http` or `https` with a host
  (`URL(followableReplyString:)`). Anything else fails the call as
  `.decoding`, which for `/fetch_bimi` is a lookup the cache retries
  rather than a cached "no logo".
- **No answer: `.network`.** `URLSessionHTTPTransport` turns every
  `URLError` but the caller's own cancel into `.network`, retrying a
  dropped connection, a timeout or a cancel nobody asked for once first.
  A reply that isn't HTTP at all is `.transport`.
- **The caller gave up: `.cancelled`.** Only when the request's own task
  was cancelled, as when SwiftUI tears down a view's `.task`. Callers that
  stay quiet on a cancel read `Task.isCancelled` rather than matching
  `.cancelled`, because some paths answer a cancel with something else:
  the folder list, for one, falls back to its saved copy.
- **This device's storage failed: `.storage`.** A keychain call; see the
  storage section below.

A first send (`CabalmailClient.send(_:)`) treats `.network`, `.transport`,
`.cancelled`, `.sendInFlight` and `.storage` as "queue the message in the
outbox and retry" (`CabalmailClient.shouldQueue`). Any other error is
thrown to the composer, which stays open and shows it. A message already
in the outbox is retried by `SendQueue`, whatever the error, until
`Outbox.maxAttempts` (a `.sendInFlight` answer doesn't spend an attempt),
then marked failed and offered back to the user (`FailedSendBanner`).

### Storage: Keychain for secrets, on-disk Codable for mirrors

- Cognito tokens: one JSON blob in the data-protection keychain
  (`KeychainSecureStore`, `kSecUseDataProtectionKeychain = true`). A
  keychain call that fails (any OSStatus but success, or not-found where
  that means absent) throws `CabalmailError.storage`, never `.transport`:
  the launch restore counts `.transport` as "offline" and passes, and a
  refresh whose new tokens can't be saved must not (#1808). The restore
  lands such a failure on the error status with the tokens kept; its first
  token read is a `try?`, so a keychain that can't be read at all (before
  the first unlock after a restart) stays signed out instead.
- Username and password: neither is stored. `CognitoAuthService`
  scrubs the `imap.username` and `imap.password` items older builds
  wrote.
- Envelopes: per-folder JSON files under the app support directory,
  keyed by UIDVALIDITY — the reconnect flow (`STATUS` + UID FETCH since
  UIDNEXT) drops straight onto this.
- Bodies: per-folder directory of raw `.eml` files, LRU-evicted by mtime
  when the total exceeds a configurable cap (default 200 MB).

### New-mail polling: `AsyncThrowingStream` over folder status

There is no IDLE. `ApiBackedImapClient.idle(folder:)` polls folder status
and yields an `IdleEvent` when `UIDNEXT` advances or the message count
drops; `MailboxWatcher` turns those events into refresh ticks and applies
the reconnect backoff, and the folder's poller (`FolderPoller`) coalesces
bursts of ticks into one STATUS for every list showing the folder.
Terminating the stream cancels the polling task.

### Rich-text editor: WKWebView contenteditable + fetched marked/turndown

`ComposeView` ships a dual-mode body — segmented "Rich Text" / "Markdown"
tabs — to match the React composer feature-for-feature. The rich pane is
a `contenteditable` `<div>` inside a `WKWebView`, driven by a SwiftUI
toolbar (`RichTextToolbar`) that calls `document.execCommand` through
`RichTextEditorController`'s JS bridge. The markdown pane is a plain
`TextEditor`; drafts persist as Markdown either way (the rich pane is
re-seeded from the markdown source on open).

At send time, `ComposeViewModel.computeMessageBodies()` runs the same
four-way table the React `handleSend` applies: both-empty, rich-only
(text body derived via turndown), markdown-only (html body derived via
marked + flattenParagraphs + styleParagraphs), or both-filled. So every
outgoing message ships with both MIME parts populated and no recipient
sees a blank message because their mail client preferred `text/html`.

#### Why a WKWebView instead of native NSTextView / UITextView

Native rich-text editing on Apple platforms means `NSAttributedString`,
and the `.data(from: ..., documentAttributes: [.documentType: .html])`
round-trip emits HTML with heavy inline-styled spans that doesn't
visually match what the React composer produces. Matching React's
specific rules (Enter as hard-break in plain paragraphs but new-list-
item inside lists, blank-line paragraph boundaries collapsed to
`<br><br>`, ZWSP placeholder trick to defeat turndown's adjacent-
newline collapsing) by hand against `NSAttributedString` is a much
larger surface than letting the same JS libraries run inside a
contenteditable.

#### Why marked + turndown are fetched, not committed

`apple/CabalmailKit/Sources/CabalmailKit/Compose/Resources/` is the
SwiftPM resource directory `editor.html` looks up its sibling scripts
from. `editor.html` and `editor-bridge.js` are first-party and
committed; `marked.umd.js`, `turndown.js`, and their MIT LICENSE files
are gitignored and materialize at build time from
`react/admin/node_modules/` via `apple/scripts/sync-vendored.sh`.

The version pins live in `react/admin/package.json`. The React composer
already lists these exact libraries as runtime dependencies, so we get
three useful properties for free by making React's manifest the single
source of truth:

- **Dependabot already watches `react/admin/package.json`** and opens
  PRs against it when CVEs land for marked or turndown. The next
  `apple.yml` run after that PR merges pulls the patched bytes
  automatically.
- **No drift between the Apple copy and the React copy is possible.**
  The CI sync step always copies from a freshly-installed
  `node_modules`, so the Apple WKWebView and the React TipTap editor
  cannot diverge on the underlying library version.
- **CodeQL doesn't scan a vendored third-party library we don't
  maintain.** The bytes aren't in the repo for it to alarm on.

We considered the obvious alternative — committing the JS verbatim
into the resource directory with a CI drift-check that diffs against
`react/admin/node_modules/` after `npm ci`. That works, but it requires
exactly the same `npm ci` step in CI, just to *verify* what we could
have *produced* instead. The fetched-not-committed design pays the
same CI cost and produces a strictly cleaner repo (no committed
upstream bytes, no manual sync flow on version bumps).

The one cost we explicitly accept: a fresh clone can't `swift test`
the kit before running `apple/scripts/sync-vendored.sh`. The error is
self-explanatory (SwiftPM names the missing resource) and the script
is a one-liner; the Bootstrap section covers it.

A root-level `vendor/` directory was also considered. SwiftPM requires
resources to live inside the target's `path:`, so a root vendor would
need symlinks (`Resources/marked.umd.js -> ../../../../../../vendor/...`),
and the kit would stop being self-contained. With these particular
libraries now sourced from npm via the React manifest, the symlink
convention has even less to recommend it. Revisit if a non-JS,
non-npm-managed vendored dep ever appears.

### Drafts: local buffer + cross-device sync

`CabalmailKit.DraftStore` persists drafts as Codable JSON under the app
support directory, keyed by UUID. `ComposeViewModel` autosaves every 5 s
while the sheet is open, so a mid-compose app kill is recoverable — this
local copy is the live editing buffer and the crash-recovery story.

Drafts also sync across devices through the `/save_draft` Lambda, which
owns a server-side lifecycle on the top-level `Drafts` mailbox. Server
saves fire on compose close-without-send (always) and on a 60-second
debounce while composing (skipped while the body is empty, while a send
is in flight, or while another server save is running). The sync is
last-writer-wins keyed on the returned `(uidvalidity, uid)`: each save
passes the prior copy's coordinates as `replaces_*`, so the Lambda
appends the new copy before expunging the old under a UIDVALIDITY guard
whose worst-case failure is a duplicate draft, never a lost one. Opening
a message in `Drafts` offers **Edit Draft**, reseeding compose from the
fetched copy — recipients and subject from the envelope, Bcc and
threading from the headers, body from the Markdown text part. Because
both first-party composers are Markdown-canonical the round trip is
lossless. See `docs/draft-sync-and-threading.md`.

### Sent-folder copy: server-side via `/send`

Neither mail tier auto-APPENDs to `Sent`. The `/send` Lambda owns the
whole outbound shuffle — Outbox APPEND, SMTP submission, and the Sent
copy (staged to S3 and written by a decoupled queue consumer, see
`lambda/api/append_sent`) — so `CabalmailClient.send(_:)` posts the
compose payload and does no client-side APPEND. Sending from a synced
draft passes the draft's `discard_draft_*` coordinates so the server
best-effort expunges the Drafts copy once delivery succeeds.

### Compose scene

- `CabalmailKit.ReplyBuilder` (pure value-type helper) turns an incoming
  `Envelope` + its decoded plain-text body + the user's owned addresses
  into a seeded `Draft`. Handles `Re:` / `Fwd:` idempotent prefixing,
  `In-Reply-To` / `References` threading, reply-all deduplication /
  self-exclusion, and the "default From to the original's addressee" rule
  that makes the on-the-fly-From idiom reusable across a whole thread.
- `CabalmailUI/Compose/ComposeView.swift` renders the SwiftUI form. From
  picker's first menu item is always "**Create new address…**" (matches
  `docs/README.md`'s primary-action framing). Attachments land via
  `PhotosPicker` (images) and `fileImporter` (arbitrary documents);
  mime-type derived from `UTType` for file imports.
- `CabalmailUI/Addresses/NewAddressSheet.swift` mirrors the React app's
  `Addresses/Request.jsx` — username / subdomain / domain / optional
  comment, with a **Random** button that seeds alphanumerics so the
  mint-an-address flow stays a one-tap affordance.

### Preferences storage: account-scoped `UserDefaults` + server sync

`CabalmailKit.Preferences` persists through a pluggable `PreferenceStore`
protocol. Production uses `UserDefaultsPreferenceStore` — plain local
`UserDefaults`, nothing else; settings never touch iCloud. Storage is
scoped per Cabalmail account: `Preferences.activate(controlDomain:
username:)` runs on sign-in / restore and switches every read and write
to that account's own keys (the shared key plus a stable hash of
domain + username), so two accounts on one device can never see or
overwrite each other's settings. Cross-device sync rides the Cabalmail
account instead: `PreferencesSyncCoordinator` stores the settings per
Cognito user on the server (`/get_preferences` / `/set_preferences`),
pulls with server-wins semantics on login and foreground, and pushes
debounced local edits.

A single `@Observable` class is used in preference to `@AppStorage`
property wrappers because multiple views (compose, message detail,
message list) need to read the same preference on the same code path,
and the SwiftUI 18 `@Observable` macro makes sharing a `Preferences`
instance across the environment cheaper than keeping a property wrapper
in each view.

### Signed-in navigation: `TabView(.sidebarAdaptable)`

`SignedInRootView` uses SwiftUI 18's `TabView(selection:)` + the
`.sidebarAdaptable` style so the same screen renders as a bottom tab bar
on iPhone and as a collapsible sidebar on iPad / visionOS / macOS. macOS
hides the Settings tab via a `#if !os(macOS)` guard because the
`Settings` scene wired to ⌘, in `CabalmailMacApp` already covers that
ground.

### Signature insertion: RFC 3676 delimiter, static helper

Signatures are inserted via `CabalmailKit.SignatureFormatter.seedBody`, a
pure value-type helper that prepends `"\n-- \n<signature>"` to the seed
body. The RFC 3676 `"-- "` (dash-dash-space) on its own line is the
canonical signature marker every UNIX mail client since Pine recognises,
so downstream clients can collapse / strip the block when threading a
long reply chain. Keeping the helper pure (and outside
`ComposeViewModel`) lets `SignatureFormatterTests` pin the three
entry-point layouts — empty-new-message,
reply/forward-with-quoted-original, and arbitrary base — without
spinning up the full view model.

### Settings surface

- **Account.** Signed-in username + control domain (both read-only), plus
  the single sign-out button. Account is the canonical place for
  sign-out.
- **Reading.** `Folder counts` first, on its own: it governs the badges
  on mail folders and feeds alike (unread / total / both). Then two
  sections, Email messages and Feed items — the feed reader is part of
  the app, not a category of its own. Email messages: `Mark as read`
  (manual / on open), `Load remote content` (off / ask / always),
  `Default view`. The manual default matches
  the React app, where the user always explicitly marks messages read
  via the swipe action, toolbar button, or context menu. Feed items:
  its own `Mark as read` (`rss_mark_as_read`), so the two habits can
  differ.
- **Composing.** `Default From address` (None / one of the user's
  addresses — revoked addresses fall back to None so a stale preference
  can't persist an address that doesn't exist any more) and a plain-text
  `Signature`. Reply / forward flows default From to the original's
  addressee, so the default-From preference only applies to new
  messages.
- **Actions.** The same two sections. Email messages: `Dispose action`
  (Archive / Trash) — `MessageListViewModel` reads this on every swipe so
  a change mid-session takes effect immediately, and the swipe label +
  icon follow the preference too — the two advance pickers, and
  `Leading swipe` / `Trailing swipe`, which bind each edge of a message
  row to Toggle read, Toggle flag, Dispose (which follows `Dispose
  action` and the in-Trash / in-Archive overrides), or None. Feed items:
  `Leading swipe` / `Trailing swipe` for feed item rows (Toggle read,
  Toggle flag, None). The same action may be bound to both edges.
  The edges are named for layout direction, not left / right, so a
  binding means the same gesture under RTL. Synced as `swipe_leading` /
  `swipe_trailing` and `rss_swipe_leading` / `rss_swipe_trailing`; the
  four ride the `app` map as a set, gated off the wire until the user
  sets one or a fetched map carries one. OPML import lives in the feeds
  sidebar's `+` menu and export under the share button beside it (both
  also in the macOS Feeds menu); neither is a setting.
- **Appearance.** `Theme` (System / Light / Dark) applied via
  `.preferredColorScheme` at the App level so the whole app flips
  instantly. `CabalmailApp` and `CabalmailMacApp` own the `AppState` and
  `Preferences` instances; the iOS `ContentView` reads them from
  `@Environment`.
- **About.** Version + build (read from `Bundle.main.infoDictionary`) and
  a link to the GitHub issues.

### Change watching is tied to the message list lifetime

`MailboxWatcher` consumes `ApiBackedImapClient.idle(folder:)`, which
polls folder status (see "New-mail polling" above), and emits `.changed` /
`.reconnecting` / `.active` ticks on an `AsyncStream`. Each folder open in
a message list has one `FolderPoller` (`MailSessionStore.folderPollers`),
which owns the folder's watcher and a 60-second tick however many windows
show the folder. `MessageListViewModel.startWatching()`, from the list's
`.task { }`, puts the list on its folder's poller, making the poller if
the list is the first; `stopWatching()`, on `.onDisappear`, takes it off,
and the last list off stops the poller. Sign-out
(`MailSessionStore.forgetAccount()`) stops every poller. The watcher stays
off while no list shows its folder — mailbox management, compose sheet,
settings — so only the mailboxes on screen are polled. When the polling
stream ends or fails, the watcher reopens it after a backoff that doubles
from 2s to 60s while reopening keeps failing. `idle(folder:)` makes its
first poll before it returns the stream, so an unreachable API fails the
reopen itself and the backoff grows.

Each `.changed` tick asks one flagged STATUS of the folder, and so does
the 60-second tick, which catches what the status poll can't see: read and
flag changes made elsewhere, and whatever arrives while the watcher backs
off. A change within a second of the last one that polled is covered by
it, so a message sweep doesn't trigger N envelope fetches, and one poll
runs at a time. Before the STATUS goes out, every list on the folder
numbers a refresh ask and holds its spinner, as its own refresh would;
each then takes the answer through `refresh(prefetched:)`, so a list with
a pill or search showing re-runs it, and a list whose own refresh is in
flight waits for it. A failed STATUS shows on a folder list as its own
refresh's failure would, and re-runs a pill's search.

### Send failures classify transient vs permanent before queueing

`CabalmailClient.send(_:)` returns `SendOutcome.sent` or `.queued`.
Transport / network errors (`CabalmailError.network`, connection
timeouts), a cancelled request, the API's duplicate-in-flight answer
(`.sendInFlight`) and a keychain that can't be read for the token
(`.storage`) queue the `OutgoingMessage` into the on-disk `Outbox` and
surface a warning toast (`CabalmailClient.shouldQueue`);
application-level rejections (auth failure, malformed recipient,
permanent SMTP 5xx) throw immediately so the compose sheet can correct
them. `SendQueue` drains the outbox when `NWPathMonitor` reports
reachability or on an explicit user kick, with `maxAttempts = 10` before
an entry is dropped so a permanently bad recipient can't spin forever.
One JSON file per entry under app support, same layout as `DraftStore`.

### MetricKit is opt-in

`Preferences.crashReportingEnabled` defaults to `false`. When the user
toggles it on in Settings → Diagnostics,
`CabalmailClient.setCrashReportingEnabled(true)` subscribes the
`MetricKitCollector` to `MXMetricManager.shared` and payloads land in
`DebugLogStore` at the `.info` level. Off by default respects the
"self-hosted email, minimum phoning-home" stance the project leans on;
the toggle is explicit and the surface for viewing what's captured is
right there (Settings → Debug Log → ShareLink). visionOS doesn't vend
MetricKit at all, so the collector is a no-op on that platform behind
`#if canImport(MetricKit) && !os(visionOS)`.

### Menu commands go to the window in front

Menu commands need to reach the view that owns the action, but
`.commands { }` is declared at the scene level, with no view to hand.
Each main window has one `WindowCommands`
(`Commands/WindowCommands.swift`), held by `SignedInRootView` beside its
`SceneNavigator`, put in the environment and published with
`focusedSceneValue`. A menu reads the front main window's object with
`@FocusedValue(\.windowCommands)`; with a compose or Settings window in
front, or none open, it reads nil and the Message, Mailbox and Feeds
menus dim. New Message stays live: it opens the compose scene itself
(#1162).

A menu sends a `WindowCommand`, which bumps that command's own count;
the surfaces that answer it watch the count with `.answersCommand(_:)`.
Surfaces report what the menus can act on
(`reportsMessageMenuAvailability`, `reportsFeedMenuAvailability`) keyed
by the surface they sit in, and the menus read the surface in front: the
window on the wide layouts, the tab in front on the tab layouts, which
keep every tab they have shown mounted (`FrontSurfacePolicy`).
`SharedChordPolicy` gives ⌘T, ⌘⇧8 and ⌥⌘T, which the Message and Feeds
menus share, to the section in front.

The shared Message menu (`MessageMenuCommands`) carries Reply ⌘R, Reply
All ⌘⇧R, Forward ⌘⇧J, Mark as Read/Unread ⌘T, Flag/Unflag ⌘⇧8 and Move
to Folder ⌘M, which deliberately shadows Window → Minimize (custom menus
match first). Dispose (⌘⌫) is NOT a menu item: menu equivalents fire
app-wide, so it would fire in the compose window and steal
delete-to-line-start mid-draft. A hidden window-scoped button carries it
(`DisposeChordButton`): the reader's for one open message, the list's
for a multi-selection, only while that surface is in front and owns the
chord. Esc and ⌘A stay focus-scoped on the list, so the search field
keeps them.

The Mailbox and Feeds commands, ⌘, and the compose hand-off still ride
`AppState` ticks aimed through `MainWindowCommandScope`'s window
identity, observed with `.onWindowCommand(tick)`. Data-change reloads
(Mark All as Read, Empty Trash, push actions) are not commands: they
bump the mail store's `listRefreshTick`, which every list observes
(#1824). A drag names the list it lifted from, and only that list
performs a sidebar drop.

### Platform polish

- **Reachability banner.** `SignedInRootView` overlays a capsule banner
  sourced from `CabalmailClient.reachability.changes()` when the network
  drops, clearing on restore.
- **Toast system.** `AppState.toast` + `showToast(_:duration:)` carries
  transient success / warning messages; `ComposeView` publishes on send
  outcome (sent → success, queued → warning).
- **visionOS hover.** `MessageListView` and `FolderListView` wrap row
  content in `.contentShape(Rectangle()).hoverEffect(.highlight)` under
  `#if os(visionOS)` so gaze focus visibly highlights rows without
  changing iOS / macOS rendering.
- **Debug Log.** `DebugLogView` (Settings → Debug Log) renders the live
  `DebugLogStore` tail with level chips, a Clear button, and a ShareLink
  that exports the current filtered buffer. Capped at 1000 visible
  entries to keep SwiftUI happy.
