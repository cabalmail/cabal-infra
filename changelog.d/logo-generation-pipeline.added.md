- **Single authoritative logo vector plus a one-command generator.**
  `vector/cabalmail-logo.svg` is now the sole source of truth for the
  Cabalmail mark, and `scripts/generate-logo-assets` (also `make logo`)
  rebuilds every derivative from it: the Apple app icons (iOS light/dark/
  tinted, a wired visionOS `AppIconVision.solidimagestack`, and the macOS
  size ladder), the React client favicon/logo set, `docs/logo.png` and
  `docs/mask.png`, and the front-door favicon. Generation is idempotent —
  version-pinned resvg + oxipng produce byte-identical, sRGB, ICC-free output
  with opaque icons flattened to RGB — and a new `Logo Assets` workflow
  regenerates on any source-vector change. Icons pick up the corrected
  optically-centered placement (`translate(94.8 145.52) scale(2.036)`), the
  disc now reads as a true stylized C (the arrow's negative space cuts
  through its right edge — visible in the standalone visionOS middle layer,
  covered by the M everywhere else), and derivatives are no longer
  hand-edited.
