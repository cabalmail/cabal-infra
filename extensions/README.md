# Cabalmail browser extensions

The address-suggesting browser extension (Chrome MV3 + Safari Web
Extension): one TypeScript codebase, two manifests. Design and phase plan:
[docs/1.x/browser-extension-plan.md](../docs/1.x/browser-extension-plan.md).

## Layout

- `shared/` — platform-agnostic core: auth (Cognito Hosted UI + PKCE), API
  client, runtime config, the form-detection scoring engine, address
  generation, the content-script controller, and the message schema. The
  analog of `apple/CabalmailKit/` and `android/kit/`.
- `chrome/` — the extension app itself (background service worker, content
  script, Preact popup and overlay) plus the Chrome manifest template. The
  Safari build reuses these sources.
- `safari/` — Safari manifest template and the Xcode host-app scaffold
  (`xcodegen generate` in `safari/`; the `.xcodeproj` and the built
  `CabalmailExtension/Resources` bundle are not committed).
- `fixtures/` — the detector corpus. `synthetic/` is hand-authored seed
  material; captured real-site snapshots (`scripts/snapshot.mjs`) land in
  sibling trees. The corpus test asserts every fixture classifies as its
  directory name says.
- `scripts/` — the build orchestrator and the snapshot tool.

## Commands

All from `extensions/` (npm workspaces; Node 20.19+/22.12+):

- `npm install` — once, and after dependency changes
- `npm run lint` — eslint over the workspace
- `npm test` — vitest (shared) + `tsc` type-check (chrome)
- `npm run build` — type-checks and produces both bundles:
  `chrome/dist/` and `safari/CabalmailExtension/Resources/`
- `cd safari && xcodegen generate` — regenerate the Xcode project (runs the
  safari web build first); then build with
  `xcodebuild -project Cabalmail.xcodeproj -scheme CabalmailExtensionHost -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO`

Build-time configuration: `CABALMAIL_CONTROL_DOMAIN` bakes the control
domain (default `cabalmail.example`, a dev placeholder); everything else is
fetched at runtime from `https://admin.<control-domain>/config.json`.
`EXTENSION_VERSION` overrides the manifest version (default: latest
CHANGELOG release).

## Loading a dev build

Build against a real environment first — the default `cabalmail.example`
placeholder produces a bundle whose config fetch (and host permission)
points nowhere, and the popup will say so:

```sh
CABALMAIL_CONTROL_DOMAIN=<control-domain> npm run build
```

- Chrome: `chrome://extensions` → Developer mode → "Load unpacked" →
  `extensions/chrome/dist`. The extension ID is pinned by the manifest
  `key`, so every unpacked dev install shares one known ID and one
  registered Cognito redirect URI (the store listing has its own,
  store-assigned ID — see docs/browser-extension.md section 4).
- Safari: the extension registers with Safari by *running the host app*.
  Build ad-hoc signed — not `CODE_SIGNING_ALLOWED=NO`, which produces a
  bundle with no signature at all, and the extension machinery can refuse
  a signature-less appex even with the unsigned-extensions toggle on:

  ```sh
  cd safari
  CABALMAIL_CONTROL_DOMAIN=<control-domain> xcodegen generate
  xcodebuild -project Cabalmail.xcodeproj -scheme CabalmailExtensionHost \
    -configuration Debug -destination 'platform=macOS' -derivedDataPath build \
    build CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=-
  open "build/Build/Products/Debug/Cabalmail Extension.app"
  ```

  Then in Safari: enable the Develop menu (Settings → Advanced), tick
  Develop → **Allow Unsigned Extensions** (admin password; resets every
  time Safari quits — re-tick each session, or run the scheme from Xcode
  with your team's automatic signing to avoid it), and enable the
  extension under Settings → Extensions, granting website access. Add
  "Allow in Private Browsing" to exercise the private-link handoff.
  While the toggle is off, Safari *hides* unsigned extensions from the
  Extensions pane entirely rather than graying them out — so an "empty"
  pane after a Safari relaunch means the toggle reset, not that
  registration was lost (`pluginkit -m | grep -i cabalmail` confirms the
  appex is still registered; `pluginkit -a <path-to-.appex>` forces
  registration in the rare case it isn't).
  Sign-in additionally needs Safari's redirect URI registered: evaluate
  `browser.identity.getRedirectURL()` in Develop → Web Extension
  Background Content → Cabalmail, then append it to
  `TF_VAR_EXTENSION_REDIRECT_URIS` (docs/browser-extension.md section 4).

The suggest/adopt flows need an environment whose backend carries the
pending-address endpoints (`/new` with `pending`, `/confirm_address`) and
whose `config.json` exposes `cognitoConfig.extensionClientId` — see the
plan's Phase 3 and the Prerequisites section.

## Forking notes

Nothing environment-specific is committed (the control domain is a
build-time env var with a deliberately fake default; all runtime values
come from your environment's `config.json`), but three identity-shaped
values are upstream's and a fork should replace them:

- **The manifest `key`** in `chrome/manifest.template.json` pins the
  unpacked-dev extension ID. Regenerate your own so your fork has its own
  identity: `openssl genrsa 2048 | openssl rsa -pubout -outform DER |
  base64` (public key only; the private half is disposable — store uploads
  strip the key entirely and the Web Store signs packages itself).
- **`CABALMAIL_REPORT_URL`** (build-time env) — where the popup's "Report
  wrong detection" link files issues. Defaults to the upstream
  cabal-infra tracker; point it at your own.
- **The Safari bundle identifiers** (`com.cabalmail.extension-host` and
  its `.web-extension` child in `safari/project.yml`) — replace with your
  own reverse-DNS prefix before registering App IDs, same as the mail
  clients under `apple/`.
