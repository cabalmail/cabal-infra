# Cabalmail — Apple Icon Handoff

Everything Claude Code needs to wire these icons into the iOS / iPadOS / macOS / visionOS Xcode projects. All sources are authored as vector SVGs at 1024×1024 — you'll need to render them to PNG at the sizes the App Icon spec requires.

## What's in this folder

| File | Purpose |
|---|---|
| `cabalmail-mark.svg` | The raw mark, transparent background. Use for website, marketing, print. |
| `AppIcon-ios-light.svg` | iOS light variant — forest on cream |
| `AppIcon-ios-dark.svg` | iOS dark variant — parchment on ink |
| `AppIcon-ios-tinted.svg` | iOS tinted variant — monochrome glyph, transparent bg |
| `AppIcon-visionos-back.svg` | visionOS back layer — cream plate only |
| `AppIcon-visionos-middle.svg` | visionOS middle layer — C-disc with arrow cutout |
| `AppIcon-visionos-front.svg` | visionOS front layer — M envelope only |

## Color tokens

```
--cm-forest:        #2E5235   (primary green)
--cm-forest-deep:   #1E3A24   (secondary green, visionOS front layer)
--cm-cream:         #F4EBD6   (primary light bg)
--cm-parchment:     #E8DFC8   (secondary light; dark-mode glyph)
--cm-ink:           #0F1A12   (primary dark bg)
--cm-ink-soft:      #16241A   (secondary dark)
```

## Geometry reference

Canvas: 1024 × 1024. The glyph is authored in a 384-unit native coordinate system placed via `translate(122 147) scale(2.036)`.

```
C-disc:              cx=96  cy=180  r=96
Arrow cutout:        tip (38,180), triangle-to-shaft joints (108,110) and (108,250),
                     shaft rect (108,146)→(154,214)  — flush against M's left edge
M envelope (5 nodes, single left edge, valley on top):
  NW (154, 84)   C (268, 176)   NE (400, 84)
  SW (154, 275)                 SE (400, 275)
  Path: NW → C → NE → SE → SW → NW
```

## iOS / iPadOS — `AppIcon.appiconset/`

Render each of the three SVGs to 1024×1024 PNG. Only one size is required by modern Xcode; the system generates derivatives.

```
AppIcon.appiconset/
├── Contents.json
├── AppIcon-light.png       (from AppIcon-ios-light.svg,  1024×1024)
├── AppIcon-dark.png        (from AppIcon-ios-dark.svg,   1024×1024)
└── AppIcon-tinted.png      (from AppIcon-ios-tinted.svg, 1024×1024, alpha preserved)
```

Contents.json skeleton:

```json
{
  "images": [
    { "filename": "AppIcon-light.png",  "idiom": "universal", "platform": "ios", "size": "1024x1024" },
    { "filename": "AppIcon-dark.png",   "idiom": "universal", "platform": "ios", "size": "1024x1024",
      "appearances": [{ "appearance": "luminosity", "value": "dark" }] },
    { "filename": "AppIcon-tinted.png", "idiom": "universal", "platform": "ios", "size": "1024x1024",
      "appearances": [{ "appearance": "luminosity", "value": "tinted" }] }
  ],
  "info": { "author": "xcode", "version": 1 }
}
```

## macOS — `AppIcon.appiconset/`

macOS still wants the full size ladder. Render `AppIcon-ios-light.svg` to each size (dark companion is optional — if you want one, render `AppIcon-ios-dark.svg` to the same set and register it under the dark appearance).

```
icon_16x16.png         (16×16)
icon_16x16@2x.png      (32×32)
icon_32x32.png         (32×32)
icon_32x32@2x.png      (64×64)
icon_128x128.png       (128×128)
icon_128x128@2x.png    (256×256)
icon_256x256.png       (256×256)
icon_256x256@2x.png    (512×512)
icon_512x512.png       (512×512)
icon_512x512@2x.png    (1024×1024)
```

## visionOS — `AppIcon.solidimagestack/`

visionOS uses a layered stack so the icon can separate in depth on gaze focus.

```
AppIcon.solidimagestack/
├── Contents.json
├── Back.solidimagestacklayer/
│   ├── Contents.json
│   └── Content.imageset/
│       ├── Contents.json
│       └── Back.png                 (from AppIcon-visionos-back.svg,   1024×1024, alpha)
├── Middle.solidimagestacklayer/
│   └── ... Middle.png               (from AppIcon-visionos-middle.svg, 1024×1024, alpha)
└── Front.solidimagestacklayer/
    └── ... Front.png                (from AppIcon-visionos-front.svg,  1024×1024, alpha)
```

Each layer's PNG must be 1024×1024 with transparency; the system composites them circularly with parallax.

## Rendering SVG → PNG

Any of these will do:

```bash
# rsvg-convert (brew install librsvg)
rsvg-convert -w 1024 -h 1024 AppIcon-ios-light.svg -o AppIcon-light.png

# Inkscape CLI
inkscape --export-type=png --export-width=1024 --export-height=1024 AppIcon-ios-light.svg

# ImageMagick (requires Inkscape or rsvg under the hood for accurate SVG)
magick -background none -density 384 AppIcon-ios-light.svg -resize 1024x1024 AppIcon-light.png
```

For the macOS ladder, loop over the sizes and re-export from the same SVG each time — don't downscale bitmaps.

## Spec compliance checklist

- [ ] All PNGs exported at exact declared sizes (no implicit scaling)
- [ ] iOS tinted variant has a fully transparent background (alpha preserved)
- [ ] visionOS layer PNGs are 1024×1024 with alpha, aligned so the glyph centers on the canvas
- [ ] No embedded ICC profiles that trip Xcode's asset catalog validator — use sRGB
- [ ] App icon has no text (✓ already the case — pure mark)
- [ ] Tested on a real device in each mode (light, dark, tinted, visionOS stand)

## Do not

- Do not apply a squircle mask yourself. Both iOS and macOS apply their own squircle clip at runtime; the exported PNG should be a full-bleed square.
- Do not bake drop-shadows into the asset. The system owns shadow rendering.
- Do not export the tinted variant as grayscale — export as monochrome white on transparent. The system tints the white pixels.

---

Ready for `xcrun actool` or a plain `xcodebuild`. Ping if any size fails validation.
