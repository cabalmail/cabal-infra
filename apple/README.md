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

Phase 2 CI (`.github/workflows/apple.yml`, landing next) runs `xcodegen generate`
before every `xcodebuild` invocation, so contributors never need to commit
generated project files.

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
#    scheme and an iPhone 17 Pro destination, and press ⌘R.
#
#    Headless equivalent (uses the default DerivedData location — do NOT
#    pass -derivedDataPath into the repo tree if the repo lives under an
#    iCloud-synced directory, or codesign will reject the .app with
#    "resource fork, Finder information, or similar detritus not allowed"):
xcodebuild -workspace Cabalmail.xcworkspace \
           -scheme Cabalmail \
           -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
           build

APP_PATH=$(xcodebuild -workspace Cabalmail.xcworkspace \
                      -scheme Cabalmail \
                      -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
                      -showBuildSettings build 2>/dev/null \
           | awk '/ BUILT_PRODUCTS_DIR = /{print $3}')/Cabalmail.app
xcrun simctl boot "iPhone 17 Pro" 2>/dev/null || true
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

## GitHub secrets for CI (Phase 2)

Phase 2 adds `.github/workflows/apple.yml` with four jobs. The `kit-test` and
`app-build` jobs run unsigned (`CODE_SIGNING_ALLOWED=NO`) and require **no**
secrets — PRs from any branch get green CI out of the box.

The `upload-ios` and `upload-mac` jobs sign, notarize, and push to TestFlight.
They are gated on the secrets below; set all six to enable them. The workflow
skips the upload jobs cleanly if they are absent.

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

These are only needed if you want `upload-mac` to produce a notarized
`.app.zip` workflow artifact for distribution outside the App Store /
TestFlight. With them missing, `upload-mac` still completes successfully
after the TestFlight upload — the developer-id steps just skip.

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
7. Encode and copy:
   ```sh
   base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy
   ```
   Paste into `APP_STORE_CONNECT_API_KEY_P8`.
8. Delete the `.p8` — it grants broad write access to your App Store Connect
   account:
   ```sh
   rm AuthKey_XXXXXXXXXX.p8
   ```

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

## What's deliberately not here yet

- Real views (Phase 4)
- Auth service and API client implementations (Phase 3)
- App icons (placeholder asset catalog slots exist)

## Open questions tracked for later phases

- **Amplify Swift vs hand-rolled Cognito SRP** — decide in Phase 3 after
  measuring Amplify's binary size impact on an otherwise-empty project.
- **Unread-count endpoint shape** — decide in Phase 7 (new endpoint vs.
  extending `list_folders`).
