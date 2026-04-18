# Cabalmail Apple Client

Native iOS / iPadOS / visionOS / macOS client for Cabalmail. See
[`docs/0.6.0/ios-client-plan.md`](../docs/0.6.0/ios-client-plan.md) for the full
plan. This directory is the Phase 1 scaffold.

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

The `.xcodeproj` is not committed. Generate it before opening the workspace:

```sh
brew install xcodegen    # one-time
cd apple
xcodegen generate
open Cabalmail.xcworkspace
```

CI (`.github/workflows/apple.yml`) runs `xcodegen generate` before every
`xcodebuild` invocation, so contributors never need to commit generated
project files.

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

## Verification (Phase 1)

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
3. **(Optional) Register both bundle identifiers** in the Developer portal
   at [developer.apple.com](https://developer.apple.com/account) →
   Certificates, Identifiers & Profiles → **Identifiers** → **+**:
   - App ID `com.cabalmail.Cabalmail` (description: `Cabalmail`)
   - App ID `com.cabalmail.CabalmailMac` (description: `Cabalmail Mac`)

   `xcodebuild -allowProvisioningUpdates` together with the Admin API
   key from the next step will auto-register these on first archive,
   so skipping this is fine. Registering manually is useful if you want
   to pre-enable specific Capabilities (Push, Associated Domains, etc.);
   otherwise leave that for later phases.
4. **Create an App Store Connect API key** with the **Admin** role. See
   [Creating the App Store Connect API key](#creating-the-app-store-connect-api-key)
   — produces the `APP_STORE_CONNECT_API_KEY_ID` /
   `APP_STORE_CONNECT_API_ISSUER_ID` / `APP_STORE_CONNECT_API_KEY_P8`
   triple.
5. **Create two App Store Connect app records** at
   [appstoreconnect.apple.com](https://appstoreconnect.apple.com) → Apps
   → **+** → New App:

   | Record | Platforms to tick | Bundle ID | Name |
   |---|---|---|---|
   | iOS / iPadOS / visionOS app | iOS ✓, visionOS ✓ | `com.cabalmail.Cabalmail` | Cabalmail |
   | macOS app | macOS ✓ | `com.cabalmail.CabalmailMac` | Cabalmail Mac |

   SKU can be anything (e.g. `cabalmail-ios`, `cabalmail-mac`); it's
   never shown publicly. Primary language English (U.S.) or whichever
   fits.

   Without these records, CI uploads land in App Store Connect but
   aren't attached to anything visible and you cannot distribute the
   build.
6. **Populate the GitHub secrets** listed in the next section.
7. **Populate TestFlight when you want to install a build.** CI uploads
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
   are out of scope for 0.6.0 but would be the next step before an App
   Store launch.

## GitHub secrets for CI

`.github/workflows/apple.yml` has four jobs. The `kit-test` and `app-build`
jobs run unsigned (`CODE_SIGNING_ALLOWED=NO`) and require **no** secrets —
PRs from any branch get green CI out of the box.

The `upload-ios` and `upload-mac` jobs sign and push to TestFlight. They are
gated on the secrets below; set all six to enable them. The workflow skips
the upload jobs cleanly if any are absent, naming the specific missing
secret(s) in the workflow summary.

Secrets may be set at the repository level (affecting all environments) or
per-environment under Settings → Environments → `stage` / `prod`.
Environment-scoped secrets override repo-level ones, so you can use a
different key set for prod than for stage if desired.

| Secret | What it is | Where to get it |
|---|---|---|
| `APPLE_TEAM_ID` | 10-character Apple Developer team ID | [developer.apple.com](https://developer.apple.com/account) → Membership details. If you belong to multiple teams, make sure you're viewing the right one. |
| `APPLE_DISTRIBUTION_CERT_P12` | base64 of your Apple Distribution `.p12` | See [Exporting the distribution certificate](#exporting-the-distribution-certificate) below |
| `APPLE_DISTRIBUTION_CERT_PASSWORD` | Password you set when exporting the `.p12` | GitHub does not accept empty secrets, so the export password must be non-empty |
| `APP_STORE_CONNECT_API_KEY_ID` | ~10-character key ID (e.g. `ABC123DEF4`) | App Store Connect → Users and Access → Integrations → Keys |
| `APP_STORE_CONNECT_API_ISSUER_ID` | UUID shown next to "Issuer ID" on the same page | — |
| `APP_STORE_CONNECT_API_KEY_P8` | base64 of the `.p8` key file | See [Creating the App Store Connect API key](#creating-the-app-store-connect-api-key) below |

The App Store Connect API key triple (`KEY_ID` + `ISSUER_ID` + `P8`) is used for
provisioning-profile fetch, TestFlight upload, and macOS `notarytool` submission
— no separate notarization credentials are needed.

**Optional — for notarized direct-distribution .app artifact:**

| Secret | What it is |
|---|---|
| `DEVELOPER_ID_CERT_P12` | base64 of your **Developer ID Application** `.p12` (different cert type from Apple Distribution) |
| `DEVELOPER_ID_CERT_PASSWORD` | Password you set when exporting the `.p12` |

See [Optional: Developer ID certificate for notarized
artifacts](#optional-developer-id-certificate-for-notarized-artifacts) for
creation/export steps.

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

### Creating the App Store Connect API key

1. App Store Connect → **Users and Access** → **Integrations** tab → **Keys**.
2. Click the **+** to generate a new key.
3. Name it something descriptive (e.g. `Cabalmail CI`). Role: **Admin**.
   App Manager is *almost* enough — it covers TestFlight uploads — but it
   cannot create or fetch provisioning profiles via the API, which
   `xcodebuild -allowProvisioningUpdates` needs during archive/export.
   Admin is the narrowest built-in role that grants both.
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

## Phase 1 Decisions

### 1. macOS: native target (not Mac Catalyst)

The plan defaults to a native macOS target because the roadmap treats macOS as
a first-class platform. Phase 1 follows that default. The macOS target
(`CabalmailMac/`) is a separate app that shares `CabalmailKit` only; views are
not reused from the iOS target. Revisit after Phase 7 polish if the duplication
becomes unacceptable.

### 2. Runtime configuration: published `config.json` (Option A)

The React app loads runtime configuration from `/config.js` on CloudFront.
`config.js`'s body happens to be valid JSON, so Terraform now writes a sibling
`config.json` object from the same template variables (see
[`terraform/infra/modules/app/s3.tf`](../terraform/infra/modules/app/s3.tf)).

The Apple client fetches `https://{control_domain}/config.json` on first launch
and caches it in `UserDefaults`. Same IPA works against dev/stage/prod by
pointing at a different control domain — only the bootstrap URL differs. The
schema is modelled by `CabalmailKit.Configuration`.

## CI workflow

`.github/workflows/apple.yml` lands with Phase 2. It has four jobs:

| Job | Runs when | What it does |
|---|---|---|
| `kit-test` | Any push touching `apple/**` or the workflow file | SwiftLint + `xcodebuild test` on CabalmailKit across macOS / iOS / visionOS destinations |
| `app-build` | Same | Unsigned `xcodebuild build` for `Cabalmail` (iOS) and `CabalmailMac` (macOS) |
| `upload-ios` | Pushes to `main` or `stage`, with the six signing secrets configured | Signed archive → TestFlight upload |
| `upload-mac` | Same | Signed App Store `.pkg` → TestFlight upload, plus a developer-id export → `notarytool submit --wait` → `stapler staple` → uploaded as a workflow artifact |

Upload jobs gracefully no-op (with a workflow warning) when secrets are
missing. Build and test jobs never require secrets.

Pinned Xcode version lives in the `XCODE_VERSION` env var at the top of the
workflow; bump it in lockstep with the deployment targets in `project.yml`
and `CabalmailKit/Package.swift`.

## Placeholder app icons

TestFlight will reject an upload that lacks app icons, so the scaffold ships
with a generated placeholder. Run this once locally to produce the PNGs and
commit them (the script has no side effects beyond writing into the two
`Assets.xcassets/AppIcon.appiconset` directories):

```sh
cd apple
scripts/generate-placeholder-icons.sh
git add Cabalmail/Assets.xcassets/AppIcon.appiconset \
        CabalmailMac/Assets.xcassets/AppIcon.appiconset
git commit -m "Add placeholder app icons"
```

The generator is deliberately ugly-but-on-brand so it's obvious we haven't
shipped real artwork yet. Replace the output files with a real design
before any non-internal distribution.

## What's deliberately not here yet

- Real views (Phase 4)
- Auth service and API client implementations (Phase 3)
- Real app icons (placeholder generated by `scripts/generate-placeholder-icons.sh`)

## Open questions tracked for later phases

- **Amplify Swift vs hand-rolled Cognito SRP** — decide in Phase 3 after
  measuring Amplify's binary size impact on an otherwise-empty project.
- **Unread-count endpoint shape** — decide in Phase 7 (new endpoint vs.
  extending `list_folders`).
