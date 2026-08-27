- **Arch packaging failed where makepkg splits debug symbols.** `cargo xtask
  package arch` read the `-debug` package that a build environment with `debug`
  in its `OPTIONS` produces — which is what the `archlinux:base-devel` image
  ships — as a leftover from an earlier build, and refused to lint anything. It
  now names the package it built and reports both artifacts.
