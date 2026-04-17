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

## What's deliberately not here yet

- Real views (Phase 4)
- Auth service and API client implementations (Phase 3)
- CI workflow (Phase 2)
- Code signing / provisioning profiles (Phase 2)
- App icons (placeholder asset catalog slots exist)

## Open questions tracked for later phases

- **Amplify Swift vs hand-rolled Cognito SRP** — decide in Phase 3 after
  measuring Amplify's binary size impact on an otherwise-empty project.
- **Unread-count endpoint shape** — decide in Phase 7 (new endpoint vs.
  extending `list_folders`).
