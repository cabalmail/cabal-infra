- **Arch package for the Linux client.** `linux/packaging/arch/PKGBUILD` builds
  the `cabalmail` binary, its man page, desktop entry, AppStream metadata, icon,
  and a commented configuration reference, and `cargo xtask package arch` builds
  it from the working tree and lints it with `namcap`. A `package-arch` job runs
  the same command in an `archlinux:base-devel` container on every push, so the
  thing a user installs is built on the push that changed it rather than at
  release time. The package's dependency arrays come from
  `linux/packaging/deps/arch.txt`, the same per-distro list the CI containers
  install from, and the composer's vendored marked and turndown are pinned
  upstream tarballs rather than an `npm` build dependency. Tests fail the build
  if the PKGBUILD and that list disagree, if the pinned JavaScript drifts from
  `react/admin/package-lock.json`, or if the package stops installing a file it
  ships. Publishing to the AUR stays a manual step.
