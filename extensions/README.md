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

- Chrome: `chrome://extensions` → Developer mode → "Load unpacked" →
  `extensions/chrome/dist`.
- Safari: build and run the `CabalmailExtensionHost` scheme, then enable
  the extension in Safari Settings → Extensions (allow unsigned extensions
  in Safari's Develop menu first).

The suggest/adopt flows need an environment whose backend carries the
pending-address endpoints (`/new` with `pending`, `/confirm_address`) and
whose `config.json` exposes `cognitoConfig.extensionClientId` — see the
plan's Phase 3 and the Prerequisites section.
