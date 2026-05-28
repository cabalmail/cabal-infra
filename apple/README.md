# Cabalmail Apple Client

Native iOS / iPadOS / visionOS / macOS client for Cabalmail. The original
implementation plan is preserved at
[`docs/0.6.0/ios-client-plan.md`](../docs/0.6.0/ios-client-plan.md) for
historical context; this README describes the as-implemented state.

## Layout

```
apple/
  project.yml                # XcodeGen spec (generates Cabalmail.xcodeproj)
  Cabalmail.xcworkspace/     # Workspace referencing the generated project + kit package
  Cabalmail/                 # iOS / iPadOS / visionOS app target (SwiftUI)
  CabalmailMac/              # Native macOS app target (SwiftUI)
  CabalmailKit/              # Shared Swift package — networking, models, auth, caching
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

| Context | How the team ID is supplied |
|---|---|
| Local (Xcode or `xcodebuild`) | Copy `Local.xcconfig.example` → `Local.xcconfig` and fill in `DEVELOPMENT_TEAM`. Gitignored. `project.yml` references it via `configFiles`, so every target picks it up automatically. |
| Headless `build` without a team ID | Pass `CODE_SIGNING_ALLOWED=NO` (see verification commands above) |
| Headless `archive` (CI upload jobs) | `xcodebuild ... DEVELOPMENT_TEAM=$APPLE_TEAM_ID archive`, team ID sourced from a GitHub secret. Command-line overrides beat the xcconfig, so CI doesn't need the file. |

Setup once:

```sh
cd apple
cp Local.xcconfig.example Local.xcconfig
# edit Local.xcconfig, set DEVELOPMENT_TEAM to your team ID
xcodegen generate
```

After that, plain `xcodebuild ... build` and `xcodebuild ... archive` both sign cleanly.

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
4. **Register both bundle identifiers** in the Developer portal at
   [developer.apple.com](https://developer.apple.com/account) →
   Certificates, Identifiers & Profiles → **Identifiers** → **+**:
   - App ID `com.cabalmail.Cabalmail` (description: `Cabalmail`)
   - App ID `com.cabalmail.CabalmailMac` (description: `Cabalmail Mac`)

   CI uses **manual code signing**, so App IDs must exist before you
   create the matching provisioning profiles in the next step.
5. **Create the provisioning profiles** for each App ID. See
   [Creating provisioning profiles](#creating-provisioning-profiles) —
   produces the `IOS_APP_STORE_PROFILE` / `MAC_APP_STORE_PROFILE` /
   (optional) `MAC_DEVID_PROFILE` secrets.
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
9. **Populate TestFlight when you want to install a build.** CI uploads
   succeed without any TestFlight setup — builds land in each app
   record's Builds list after ~5–30 minutes of Apple-side processing.
   Before anyone (including you) can install one, you need a testing
   group to attach it to:
   - App Store Connect → your app → **TestFlight** tab → **Internal
     Testing** → **+** to create a group (e.g. `Stage`, `Prod`).
   - Add your Apple ID (with an App Store Connect role) as a tester.
   - Attach the build manually the first time, or enable automatic
     distribution on the group for future uploads.
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
| `IOS_APP_STORE_PROFILE` | base64 of the `.mobileprovision` for `com.cabalmail.Cabalmail` (App Store distribution). See [Creating provisioning profiles](#creating-provisioning-profiles) below. |

**Required (macOS job only):**

| Secret | What it is |
|---|---|
| `MAC_APP_STORE_PROFILE` | base64 of the `.provisionprofile` for `com.cabalmail.CabalmailMac` (App Store distribution). |
| `MAC_INSTALLER_CERT_P12` | base64 of a **Mac Installer Distribution** `.p12`. The outer `.pkg` that wraps the macOS `.app` is signed with this cert (distinct from `Apple Distribution`, which signs the `.app` bundle itself). See [Exporting the Mac Installer certificate](#exporting-the-mac-installer-certificate). |
| `MAC_INSTALLER_CERT_PASSWORD` | Password used when exporting the `.p12`. Must be non-empty. |

**Optional (macOS notarized `.app` artifact):**

| Secret | What it is |
|---|---|
| `DEVELOPER_ID_CERT_P12` | base64 of your **Developer ID Application** `.p12` (different cert type from Apple Distribution) |
| `DEVELOPER_ID_CERT_PASSWORD` | Password you set when exporting the `.p12` |
| `MAC_DEVID_PROFILE` | base64 of the `.provisionprofile` for `com.cabalmail.CabalmailMac` (Developer ID distribution). Both `DEVELOPER_ID_CERT_P12` and this must be set to produce the notarized artifact; either missing one and the job completes after the TestFlight upload and skips notarization. |

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

1. **Register the App IDs** (one-time) at
   [developer.apple.com → Identifiers](https://developer.apple.com/account/resources/identifiers/list)
   → **+**, if you haven't already:
   - `com.cabalmail.Cabalmail` (App IDs → iOS, tvOS, watchOS, visionOS)
   - `com.cabalmail.CabalmailMac` (App IDs → macOS)

2. **Create the profiles** at
   [developer.apple.com → Profiles](https://developer.apple.com/account/resources/profiles/list)
   → **+**:

   | Profile | Distribution type | App ID | Certificate | Filename extension |
   |---|---|---|---|---|
   | Cabalmail iOS App Store | App Store | `com.cabalmail.Cabalmail` | Apple Distribution | `.mobileprovision` |
   | Cabalmail macOS App Store | App Store | `com.cabalmail.CabalmailMac` | Apple Distribution | `.provisionprofile` |
   | Cabalmail macOS Developer ID *(optional)* | Developer ID | `com.cabalmail.CabalmailMac` | Developer ID Application | `.provisionprofile` |

   Profile names are arbitrary — CI matches by the UUID embedded in the
   file, not the name.

3. **Download each profile** (click the profile → **Download**).

4. **Base64-encode each** and paste into the matching GitHub secret:
   ```sh
   base64 -i "Cabalmail_iOS_App_Store.mobileprovision" | tr -d '\n' | pbcopy
   ```
   | Downloaded file | GitHub secret |
   |---|---|
   | iOS `.mobileprovision` | `IOS_APP_STORE_PROFILE` |
   | macOS App Store `.provisionprofile` | `MAC_APP_STORE_PROFILE` |
   | macOS Developer ID `.provisionprofile` | `MAC_DEVID_PROFILE` |

5. **Delete the downloaded files** — they embed the team's distribution
   cert public key and the App ID's capabilities, and can be re-created
   from the portal if you need them again.

### Creating the App Store Connect API key

1. App Store Connect → **Users and Access** → **Integrations** tab → **Keys**.
2. Click the **+** to generate a new key.
3. Name it something descriptive (e.g. `Cabalmail CI`). Role: **App Manager**.
   App Manager covers everything CI needs — TestFlight upload and
   notarization — because archives sign manually and don't call the
   profile-creation API.
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
| `kit-test` | Any push touching `apple/**` or the workflow file | SwiftLint + `xcodebuild test` on CabalmailKit across macOS / iOS / visionOS destinations |
| `app-build` | Same | Unsigned `xcodebuild build` for `Cabalmail` (iOS) and `CabalmailMac` (macOS) |
| `upload-ios` | Pushes to `main` or `stage`, with the seven signing secrets configured | Manual-signed archive → TestFlight upload |
| `upload-mac` | Same | Manual-signed App Store `.pkg` → TestFlight upload, plus (optional) a Developer ID export → `notarytool submit --wait` → `stapler staple` → uploaded as a workflow artifact |

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
the build appears in your app's **Builds** list. First-time attach:

1. App Store Connect → your app → **TestFlight** tab → pick the `Stage`
   or `Prod` internal group → **Builds** section → **+** → attach the
   just-processed build. Toggle **Automatically distribute builds** on
   the group if you want future uploads attached without clicking.
2. On your device, install the **TestFlight** app from the App Store.
3. Sign in with the Apple ID that is a member of the group and accept
   the invite from the TestFlight inbox. The build installs like any
   App Store app, with a small yellow dot marking it as a beta.

macOS follows the same flow using the macOS TestFlight app (install
from the Mac App Store).

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
   on developer.apple.com (the form replaced the older
   `default-app-requests@apple.com` address). The form asks the
   submitter to confirm, among other things, that:
   - the app specifies the `mailto:` scheme in its `Info.plist`,
   - the app can send a message to any valid email recipient,
   - invoking the `mailto:` handler opens a new compose view with
     the To: address set to the target of the URL,
   - the app can receive a message from any email sender.

   All four are true of Cabalmail today; the wiring is in place and
   the unit tests in `CabalmailKit/Tests/CabalmailKitTests/MailtoURLTests.swift`
   cover the parser. Apple reviews and grants the entitlement
   against your team.
2. After approval, regenerate the iOS distribution provisioning
   profile in App Store Connect (the profile must list the new
   entitlement). Pull the regenerated profile into CI's
   `IOS_APP_STORE_PROFILE_UUID` secret.
3. Add `apple/Cabalmail/Cabalmail.entitlements` with the key:

   ```xml
   <key>com.apple.developer.mail-client</key>
   <true/>
   ```

4. Wire it into the iOS target's `settings.base` block in
   `apple/project.yml` (matching the macOS target's pattern):

   ```yaml
   CODE_SIGN_ENTITLEMENTS: Cabalmail/Cabalmail.entitlements
   ```

5. Regenerate the Xcode project (`xcodegen generate`) and ship a new
   TestFlight build against the updated profile.

Doing step 3 / 4 *before* Apple approves the entitlement will break
CI signing, so the entitlement file isn't checked in. Apple's rules
also forbid combining `com.apple.developer.mail-client` with
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
https://github.com/cabalmail/cabal-infra (see apple/Cabalmail/
CabalmailApp.swift and apple/CabalmailKit/Sources/CabalmailKit/
Compose/MailtoURL.swift).

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
   filtering and fail2ban but no sender allowlist.
```

References:
- [`com.apple.developer.mail-client`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.mail-client)
- [Apple Developer forum thread on the approval flow](https://developer.apple.com/forums/thread/650300)

## App icons

Real Cabalmail artwork is installed in both asset catalogs, rendered from
the vector sources in [`apple/handoff/`](handoff/) (authored by Claude
Design; see [`handoff/README.md`](handoff/README.md) for the full spec
including geometry, color tokens, and the per-platform do-not list).

```
apple/Cabalmail/Assets.xcassets/AppIcon.appiconset/
  AppIcon-light.png      (1024×1024, from AppIcon-ios-light.svg)
  AppIcon-dark.png       (1024×1024, from AppIcon-ios-dark.svg)
  AppIcon-tinted.png     (1024×1024 RGBA, from AppIcon-ios-tinted.svg —
                          white glyph on transparent; system tints the
                          white pixels at runtime)
apple/CabalmailMac/Assets.xcassets/AppIcon.appiconset/
  icon_16x16.png … icon_512x512@2x.png    (the full 10-file macOS ladder,
                                          re-rendered from the light SVG
                                          at each exact size — no bitmap
                                          downscaling)
```

`Contents.json` in the iOS catalog uses the iOS 17+ `appearances`
convention (`luminosity: dark` / `luminosity: tinted`) rather than the
legacy single-idiom layout.

Both catalogs pass `xcrun actool` cleanly (iphoneos 18, macosx 15, xros 2).

### Regenerating from the SVG sources

```sh
brew install librsvg                  # one-time
cd apple

# iOS / iPadOS / visionOS variants
IOS="Cabalmail/Assets.xcassets/AppIcon.appiconset"
rsvg-convert -w 1024 -h 1024 handoff/AppIcon-ios-light.svg   -o "$IOS/AppIcon-light.png"
rsvg-convert -w 1024 -h 1024 handoff/AppIcon-ios-dark.svg    -o "$IOS/AppIcon-dark.png"
rsvg-convert -w 1024 -h 1024 handoff/AppIcon-ios-tinted.svg  -o "$IOS/AppIcon-tinted.png"

# macOS ladder
MAC="CabalmailMac/Assets.xcassets/AppIcon.appiconset"
for pair in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x \
            128:icon_128x128 256:icon_128x128@2x 256:icon_256x256 512:icon_256x256@2x \
            512:icon_512x512 1024:icon_512x512@2x; do
  size="${pair%%:*}"; name="${pair##*:}"
  rsvg-convert -w "$size" -h "$size" handoff/AppIcon-ios-light.svg -o "$MAC/${name}.png"
done
```

Do **not** apply a squircle mask, bake a drop-shadow, or grayscale the
tinted variant in any regen pipeline — iOS / macOS / visionOS each own
those at runtime. The handoff README spells this out.

### visionOS is currently on the shared iOS `.appiconset`

visionOS apps can ship a layered `AppIcon.solidimagestack` (back / middle
/ front layers, composited with parallax on gaze focus). The three
visionOS source layers already exist in `apple/handoff/`
(`AppIcon-visionos-{back,middle,front}.svg`), but the current build does
**not** install them. The `Cabalmail` target's visionOS destination is
served by the same `AppIcon.appiconset` as iOS/iPadOS, which is a valid
visionOS icon configuration — just not the layered one.

Adding the solidimagestack requires a new `AppIcon.solidimagestack`
asset, per-layer `Content.imageset/Contents.json` files, and a
per-platform icon name wired through `project.yml` (e.g.
`ASSETCATALOG_COMPILER_APPICON_NAME` overridden for xros). Validating
the parallax result requires a visionOS device in the loop.

## Architecture

### macOS: native target (not Mac Catalyst)

The roadmap treats macOS as a first-class platform, so the macOS target
is native rather than Mac Catalyst. `CabalmailMac/` is a separate app
that shares `CabalmailKit` only; views are not reused from the iOS
target.

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

### IMAP: hand-rolled on `NWConnection`

`CabalmailKit` ships a small hand-rolled IMAP client (`LiveImapClient`)
built on `NWConnection` + a byte-accurate response parser, rather than
`swift-nio-imap` or `MailCore2`. Trade-offs:

- **For us:** zero external SwiftPM packages (simpler CI, no network
  resolution, no visionOS build surprises); the parser handles the exact
  subset of RFC 3501 we need (envelopes, flags, body literals,
  bodystructure-as-attachment-heuristic, status, search, list/lsub).
- **Against:** we own the IMAP parser. Real servers emit corner cases we
  haven't seen yet.

See the top-level [`CLAUDE.md`](../CLAUDE.md) for the production wiring:
the live mail traffic goes through `ApiBackedImapClient` against the
Lambda API surface, not `LiveImapClient` direct-to-IMAP.

### SMTP submission: implicit TLS on 465 instead of STARTTLS on 587

`NWConnection`'s TLS stack attaches at connect time, so a clean STARTTLS
upgrade requires a custom framer — meaningfully more code with no
operational upside. The submission listener already binds 465 as well as
587 (see
[`terraform/infra/modules/elb/main.tf`](../terraform/infra/modules/elb/main.tf)),
and implicit-TLS on 465 is operationally equivalent to STARTTLS on 587,
so `LiveSmtpClient` defaults to 465. `NetworkByteStream.startTLS(host:)`
throws deliberately so future contributors see exactly why the upgrade
path isn't available.

### Storage: Keychain for secrets, on-disk Codable for mirrors

- Cognito tokens: one JSON blob in the data-protection keychain
  (`KeychainSecureStore`, `kSecUseDataProtectionKeychain = true`).
- IMAP username + password: separate keychain items keyed to the tokens
  so sign-out cleans them up together.
- Envelopes: per-folder JSON files under the app support directory,
  keyed by UIDVALIDITY — the reconnect flow (`STATUS` + UID FETCH since
  UIDNEXT) drops straight onto this.
- Bodies: per-folder directory of raw `.eml` files, LRU-evicted by mtime
  when the total exceeds a configurable cap (default 200 MB).

### IDLE: separate connection, `AsyncThrowingStream`

`LiveImapClient.idle(folder:)` opens a second authenticated connection
dedicated to IDLE so foreground mailbox operations aren't blocked by the
open IDLE socket. Untagged `EXISTS` / `EXPUNGE` / `FETCH` events stream
via `AsyncThrowingStream<IdleEvent, Error>`; terminating the stream
cancels the reader task, issues `DONE\r\n`, and closes the connection.

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

### Drafts: local only

`CabalmailKit.DraftStore` persists drafts as Codable JSON under the app
support directory, keyed by UUID. `ComposeViewModel` autosaves every 5 s
while the sheet is open, so a mid-compose app kill is recoverable.

### Sent-folder APPEND: client-side after successful submission

Neither mail tier auto-APPENDs to `Sent`; the React app's backend
replicates the message into `Sent` from the `send` Lambda (see
`lambda/api/send/function.py`). `CabalmailClient.send(_:)` mirrors that
behavior: it stamps a shared `Message-ID`, submits via SMTP, and
best-effort-APPENDs the same payload to `Sent` with `\Seen` set. The
APPEND is best-effort because a failed Sent-folder write on an
already-delivered message shouldn't surface as a send failure.

### Compose scene

- `CabalmailKit.ReplyBuilder` (pure value-type helper) turns an incoming
  `Envelope` + its decoded plain-text body + the user's owned addresses
  into a seeded `Draft`. Handles `Re:` / `Fwd:` idempotent prefixing,
  `In-Reply-To` / `References` threading, reply-all deduplication /
  self-exclusion, and the "default From to the original's addressee" rule
  that makes the on-the-fly-From idiom reusable across a whole thread.
- `Cabalmail/Views/ComposeView.swift` renders the SwiftUI form. From
  picker's first menu item is always "**Create new address…**" (matches
  `docs/README.md`'s primary-action framing). Attachments land via
  `PhotosPicker` (images) and `fileImporter` (arbitrary documents);
  mime-type derived from `UTType` for file imports.
- `Cabalmail/Views/NewAddressSheet.swift` mirrors the React app's
  `Addresses/Request.jsx` — username / subdomain / domain / optional
  comment, with a **Random** button that seeds alphanumerics so the
  mint-an-address flow stays a one-tap affordance.

### Preferences storage: `UserDefaults` + `NSUbiquitousKeyValueStore`

`CabalmailKit.Preferences` persists through a pluggable `PreferenceStore`
protocol. Production uses `UbiquitousPreferenceStore`, which writes to
both `UserDefaults` (fast local reads) and `NSUbiquitousKeyValueStore`
(cross-device sync via iCloud). An
`NSUbiquitousKeyValueStoreDidChangeExternallyNotification` observer
mirrors every pushed key back into `UserDefaults` so subsequent
synchronous reads stay fast. The store degrades gracefully on an
iCloud-disabled install — the ubiquitous half becomes a no-op and
`UserDefaults` carries the whole load.

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
- **Reading.** `Mark as read` (manual / on open / after delay) and
  `Load remote content` (off / ask / always). `MessageDetailViewModel`
  schedules a cancellable 2-second task for `.afterDelay` that the view
  cancels on disappear so we don't mark read a message the user only
  previewed.
- **Composing.** `Default From address` (None / one of the user's
  addresses — revoked addresses fall back to None so a stale preference
  can't persist an address that doesn't exist any more) and a plain-text
  `Signature`. Reply / forward flows default From to the original's
  addressee, so the default-From preference only applies to new
  messages.
- **Actions.** `Dispose action` (Archive / Trash). `MessageListViewModel`
  reads this on every swipe so a change mid-session takes effect
  immediately; the swipe label + icon follow the preference too.
- **Appearance.** `Theme` (System / Light / Dark) applied via
  `.preferredColorScheme` at the App level so the whole app flips
  instantly. `CabalmailApp` and `CabalmailMacApp` own the `AppState` and
  `Preferences` instances; the iOS `ContentView` reads them from
  `@Environment`.
- **About.** Version + build (read from `Bundle.main.infoDictionary`) and
  a link to the GitHub issues.

### IDLE is tied to the message list lifetime

`MailboxWatcher` opens a dedicated IDLE connection and emits `.changed` /
`.reconnecting` / `.active` ticks on an `AsyncStream`.
`MessageListViewModel.startWatching()` drives it from the message list's
`.task { }` and stops it on `.onDisappear`. The watcher stays off while
the user is elsewhere — mailbox management, compose sheet, settings — so
the server only holds one open IDLE socket per active mailbox.
Reconnects use bounded exponential backoff (2s → 60s) per RFC 2177's
29-minute disconnect cadence; consecutive `EXISTS` bursts are coalesced
on the view-model side with a 1-second refresh floor so a message sweep
doesn't trigger N envelope fetches.

### Send failures classify transient vs permanent before queueing

`CabalmailClient.send(_:)` returns `SendOutcome.sent` or `.queued`.
Transport / network errors (`CabalmailError.network`, connection
timeouts) queue the `OutgoingMessage` into the on-disk `Outbox` and
surface a warning toast; application-level rejections (auth failure,
malformed recipient, permanent SMTP 5xx) throw immediately so the
compose sheet can correct them. `SendQueue` drains the outbox when
`NWPathMonitor` reports reachability or on an explicit user kick, with
`maxAttempts = 10` before an entry is dropped so a permanently bad
recipient can't spin forever. One JSON file per entry under app support,
same layout as `DraftStore`.

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

### Commands dispatch through `AppState` tick counters

macOS menu commands (File → New Message ⌘N, Mailbox → Refresh ⌘R) and
iOS keyboard shortcuts need to reach whichever view currently owns the
action — but `.commands { }` is defined at the scene level, so there's
no direct reference to the focused view. `AppState` exposes two
monotonic counters (`composeRequestTick`, `refreshRequestTick`);
`MessageListView` / `SignedInRootView` watch them with `.onChange` and
act on each bump. Avoids the `@FocusedValue` / responder-chain dance,
and the same tick flow works on iOS (shortcuts) and macOS (menu bar).
Reply (⌘R), Reply-All (⌘⇧D), Forward (⌘⇧J) are local to
`MessageDetailView` and use plain `.keyboardShortcut` on the toolbar
buttons.

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
