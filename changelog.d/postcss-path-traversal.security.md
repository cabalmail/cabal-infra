- **Patched `postcss` in `react/admin`.** Bumped the build-tooling `postcss`
  dependency (pulled in transitively by Vite) from 8.5.15 to 8.5.23, past the
  8.5.18 fix for a path-traversal bug in previous-source-map auto-loading that
  could disclose arbitrary `.map` files.
