# Cabalmail logo — authoritative vector

`cabalmail-logo.svg` is the **single source of truth** for the Cabalmail
mark. It is a tight-bounds glyph (viewBox `0 84 400 192`, `currentColor`
fill) whose header comment documents the geometry. Every logo derivative in
the repo — Apple app icons, the Android Play Store icon, the React client
favicon/logo set, the docs images, and the front-door favicon — is generated
from this one file.

**Do not hand-edit any derivative.** Edit this vector (or a constant in the
generator), then regenerate:

```sh
make logo            # or: ./scripts/generate-logo-assets
```

That one command rebuilds everything. It is idempotent — a version-pinned
[resvg](https://github.com/linebender/resvg) rasterizes the art and a
version-pinned [oxipng](https://github.com/shssoichiro/oxipng) optimizes it,
so re-running (on macOS or in CI) produces byte-identical output. See
`scripts/generate-logo-assets --help` for the full output inventory and the
rasterizer fallback chain.

## Layout

```
vector/
├── cabalmail-logo.svg   AUTHORITATIVE SOURCE — the only file you edit
├── derived/             GENERATED intermediate SVG treatments (render inputs)
└── README.md            this file
```

`derived/` holds the eleven SVG treatments the generator composes from the
source (the seven Apple treatments plus the web favicon, in-app logo,
front-door mark, and docs silhouette). They carry a `DO NOT EDIT` banner and
exist so the exact render inputs are reviewable in the diff; they are
overwritten on every run.

## Where the derivatives land

| Consumer | Files |
|---|---|
| iOS / iPadOS | `apple/Cabalmail/Assets.xcassets/AppIcon.appiconset` (light / dark / tinted) |
| visionOS | `apple/Cabalmail/Assets.xcassets/AppIconVision.solidimagestack` (back / middle / front) |
| macOS | `apple/CabalmailMac/Assets.xcassets/AppIcon.appiconset` (16→1024 ladder) |
| App sidebar | `apple/{Cabalmail,CabalmailMac}/Assets.xcassets/CabalmailMark.imageset` |
| Android (Play Store) | `android/app/src/main/ic_launcher-playstore.png` (512×512 opaque PNG for the Play Console listing; not packaged into the APK) |
| React client | `react/admin/public/{favicon.svg,favicon.ico,logo192.png,logo384.png,mask.png}`, `react/admin/src/assets/logo.svg` |
| Repo docs | `docs/logo.png`, `docs/mask.png` |
| Landing site | `front-door/assets/cabalmail-mark.svg` |

## Geometry & palette

The glyph is a 384-unit native mark: a stylized letter **C** (a disc whose
arrow of negative space cuts clear through to the disc's right edge, opening
it) plus the M envelope, whose left edge covers the opening in composed
treatments — only the standalone disc (the visionOS middle icon layer) shows
the C open. It is placed on the 1024 icon canvas via
`translate(94.8 145.52) scale(2.036)` — optically centered (geometric center
with a −10px x correction). The color
tokens (forest `#2E5235`, forest-deep `#1E3A24`, cream `#F4EBD6`, parchment
`#E8DFC8`, ink `#0F1A12`, ink-soft `#16241A`) and the per-platform do-not
list (no squircle mask, no baked shadow, tinted = white-on-transparent) live
in the generator's header and constants. Do not re-derive the placement by
eye — the string above is the spec.
