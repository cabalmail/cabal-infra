- **Colour tokens: one source of truth for every client.**
  `design/color-tokens.json` holds the palette Claude Design produced for the
  colour audit, and `scripts/generate-color-tokens.py` exports it to an asset
  catalog in CabalmailKit (light, dark, Increase Contrast, and watch
  variants), Android colour resources with Compose accessors, and React
  custom properties. The generator re-checks the exported sRGB values
  against the WCAG floors before writing, and each client's test suite
  fails if the generated files drift from the token file. No call site
  changes yet; adoption follows per client.
