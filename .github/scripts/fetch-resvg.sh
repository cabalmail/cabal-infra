#!/usr/bin/env bash
#
# Fetch and sha256-verify the static `resvg` SVG rasterizer, installing the
# binary to a destination path. Two consumers share this fetcher:
#
#   1. The fetch_bimi Lambda bundles it to render BIMI SVG logos to PNG:
#      SwiftUI's AsyncImage cannot decode SVG, so the endpoint must serve a
#      raster. resvg is a single self-contained binary (no system libraries),
#      so it drops cleanly into the zip without a container. The Lambda runs
#      on x86_64 (resvg ships no linux-aarch64 build), which is why this
#      script defaults to the `linux-x86_64` target - callers that omit the
#      target argument keep the exact pre-existing behaviour.
#
#   2. scripts/generate-logo-assets uses it as the canonical, version-pinned
#      rasterizer for the brand-logo pipeline. Because the logo art is
#      font-free vector geometry, a pinned resvg produces byte-identical PNGs
#      across macOS (local regen) and linux (CI), which is what makes the
#      generated assets reproducible. That caller passes an explicit host
#      target (e.g. `macos-aarch64`).
#
# The binary is fetched + verified at build time, never committed to the
# repo, so it stays out of version control and pinned by hash like the pip
# deps.
#
# Usage:
#   fetch-resvg.sh <dest_path> [target]
#
#   target : one of linux-x86_64 (default), macos-aarch64, macos-x86_64

set -euo pipefail

RESVG_VERSION="0.47.0"

DEST="${1:?[fetch-resvg] destination path required}"
TARGET="${2:-linux-x86_64}"

# sha256 of the release archive for each supported target of the pinned
# version. Update all three together when bumping RESVG_VERSION.
case "${TARGET}" in
  linux-x86_64)
    ARCHIVE="resvg-linux-x86_64.tar.gz"
    SHA256="5c84dcbcd032fe7e8d96e616fd6807a2f9df6561d2e6582b37e91e63c6cb4fe7"
    ;;
  macos-aarch64)
    ARCHIVE="resvg-macos-aarch64.zip"
    SHA256="049f8cc5666ff6395987798feae04f7f31525b0047b063d8e07fcbb8d22f3675"
    ;;
  macos-x86_64)
    ARCHIVE="resvg-macos-x86_64.zip"
    SHA256="3f6d9ffb72ea347f964770b38a71b2f181209190e77278bbb9f179c0d05a0eaa"
    ;;
  *)
    echo "[fetch-resvg] unsupported target: ${TARGET}" >&2
    echo "[fetch-resvg] supported: linux-x86_64, macos-aarch64, macos-x86_64" >&2
    exit 1
    ;;
esac

URL="https://github.com/linebender/resvg/releases/download/v${RESVG_VERSION}/${ARCHIVE}"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

echo "[fetch-resvg] downloading resvg ${RESVG_VERSION} (${TARGET})"
curl -fsSL -o "${tmp}/${ARCHIVE}" "${URL}"

echo "[fetch-resvg] verifying sha256"
# sha256sum on linux, shasum on macOS.
if command -v sha256sum >/dev/null 2>&1; then
  echo "${SHA256}  ${tmp}/${ARCHIVE}" | sha256sum -c -
else
  echo "${SHA256}  ${tmp}/${ARCHIVE}" | shasum -a 256 -c -
fi

case "${ARCHIVE}" in
  *.tar.gz) tar -xzf "${tmp}/${ARCHIVE}" -C "${tmp}" resvg ;;
  *.zip)    unzip -o -q "${tmp}/${ARCHIVE}" resvg -d "${tmp}" ;;
esac

install -m 0755 "${tmp}/resvg" "${DEST}"
echo "[fetch-resvg] installed resvg -> ${DEST}"
