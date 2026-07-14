- Apple: **macOS app icon now follows the system Appearance setting.** The
  macOS icon stayed light in Dark mode because an asset catalog's
  `luminosity` appearance variants are dropped by the icon compiler for the
  Mac idiom (they produce a legacy, appearance-blind icon). The macOS and
  iOS/iPadOS square icons are now a shared Icon Composer `.icon` bundle,
  generated from the same source vector, so macOS renders forest-on-cream in
  Default and parchment-on-ink in Dark — matching iOS.
