#!/usr/bin/env bash
#
# Install the Linux client's build dependencies from the one list that
# describes them: linux/packaging/deps/<distro>.txt. The CI containers, the
# Debian control file (Phase 8), the Arch PKGBUILD's dependency arrays, and
# anyone setting up a machine by hand all read those files, so a new dependency
# is added in one place.
#
# Usage: .github/scripts/install-linux-deps.sh <distro>
#
# <distro> is the list to read and the package manager to read it with:
# `ubuntu` for apt, `arch` for pacman.
#
# Run from the repository root, as root (which is what a container job is).

set -euo pipefail

DISTRO="${1:-}"
if [ -z "$DISTRO" ]; then
  echo "[linux-deps] usage: $0 <distro>" >&2
  exit 1
fi

DEPS_FILE="linux/packaging/deps/${DISTRO}.txt"
if [ ! -f "$DEPS_FILE" ]; then
  echo "[linux-deps] no dependency list at $DEPS_FILE" >&2
  exit 1
fi

# Strip comments and blank lines; what is left is package names.
mapfile -t PACKAGES < <(grep -vE '^[[:space:]]*(#|$)' "$DEPS_FILE")
if [ "${#PACKAGES[@]}" -eq 0 ]; then
  echo "[linux-deps] $DEPS_FILE lists no packages" >&2
  exit 1
fi

echo "[linux-deps] installing ${#PACKAGES[@]} packages from $DEPS_FILE:"
printf '[linux-deps]   %s\n' "${PACKAGES[@]}"

case "$DISTRO" in
  ubuntu|debian)
    apt-get update
    apt-get install -y --no-install-recommends "${PACKAGES[@]}"
    ;;
  arch)
    # A full upgrade, not `-Sy` alone: Arch supports no other transition, and a
    # partial upgrade inside a stale container image is how a build acquires a
    # library its packages were not linked against.
    pacman -Syu --needed --noconfirm "${PACKAGES[@]}"
    ;;
  *)
    echo "[linux-deps] no package manager known for '$DISTRO'" >&2
    exit 1
    ;;
esac
