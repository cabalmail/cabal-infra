# Claude Code — Cabalmail icon installation prompt

Copy this entire block into Claude Code from the repo root.

---

I have a finished Apple icon suite for a product called **Cabalmail** sitting in `handoff/` at the repo root. Please install the icons into my Xcode project. The package includes a `README.md` with the full spec, seven source SVGs at 1024×1024, and color tokens.

Please:

1. **Read `handoff/README.md`** end-to-end — it's the single source of truth for sizes, color tokens, file layout, and the do-not list.

2. **Detect which targets exist** in this repo. Look for `*.xcodeproj` / `Package.swift` / `AppIcon.appiconset/` / `AppIcon.solidimagestack/`. Tell me which of (iOS, iPadOS, macOS, visionOS) are present before you make changes.

3. **For each present target:**
   - Render the relevant SVGs to the PNG sizes `README.md` specifies. Use `rsvg-convert` if available, otherwise Inkscape CLI, otherwise ImageMagick with density 384. Re-render from the SVG at every size — do not downscale bitmaps.
   - Replace the existing `AppIcon.appiconset/` (iOS/iPadOS/macOS) or `AppIcon.solidimagestack/` (visionOS) contents. Preserve the path where the asset catalog lives; just swap the files inside.
   - Write a matching `Contents.json` using the skeleton in `README.md` (iOS: three variants with `appearances`; macOS: full size ladder; visionOS: three layers each with their own `Contents.json`).
   - For visionOS, verify each layer PNG is 1024×1024 with alpha.
   - For iOS tinted, verify the exported PNG has a transparent background (not white).

4. **Add color tokens.** If the project has a central color/theme file (SwiftUI `Color` extension, `Assets.xcassets/Colors/`, `Tokens.swift`, etc.) add the six tokens from `README.md` (`cmForest`, `cmForestDeep`, `cmCream`, `cmParchment`, `cmInk`, `cmInkSoft`). If there's no existing convention, create `Sources/Shared/CabalmailTokens.swift` with a `Color` extension. Do not edit view code to consume them — just make them available.

5. **Validate.** Run `xcrun actool --validate …` against each asset catalog (or `xcodebuild -target … build` if actool isn't wired). Report any validator errors and fix them. A green build is not required — the assets passing actool is.

6. **Report back** with:
   - The targets you touched
   - The exact files added/replaced
   - Any validator warnings
   - The command to run to see the new icons on a simulator or device

**Constraints:**
- Don't apply a squircle mask to the exported PNGs. iOS/macOS/visionOS all apply their own clip at runtime.
- Don't bake drop-shadows. The system owns shadow rendering.
- Don't export the tinted variant as grayscale — it must be white-on-transparent.
- Don't commit the PNGs unless I already commit other generated assets. Check `.gitignore` before git-adding anything.

If any step is ambiguous for this specific repo layout, stop and ask instead of guessing.
