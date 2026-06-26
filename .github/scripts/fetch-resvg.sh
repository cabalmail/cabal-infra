#!/usr/bin/env bash
#
# Fetch and sha256-verify the static `resvg` SVG rasterizer, installing the
# binary to a destination path. The fetch_bimi Lambda bundles it to render
# BIMI SVG logos to PNG: SwiftUI's AsyncImage cannot decode SVG, so the
# endpoint must serve a raster. resvg is a single self-contained binary (no
# system libraries), so it drops cleanly into the zip without a container.
#
# resvg ships a prebuilt binary for linux-x86_64 only - no linux-aarch64 -
# which is why the fetch_bimi Lambda runs on x86_64 while the rest of the
# API fleet is arm64 (see terraform/.../modules/call/lambda.tf). The binary
# is fetched + verified here at build time, never committed to the repo, so
# it stays out of version control and pinned by hash like the pip deps.
#
# Usage:
#   fetch-resvg.sh <dest_path>

set -euo pipefail

RESVG_VERSION="0.47.0"
# sha256 of resvg-linux-x86_64.tar.gz for the pinned version.
RESVG_SHA256="5c84dcbcd032fe7e8d96e616fd6807a2f9df6561d2e6582b37e91e63c6cb4fe7"
RESVG_URL="https://github.com/linebender/resvg/releases/download/v${RESVG_VERSION}/resvg-linux-x86_64.tar.gz"

DEST="${1:?[fetch-resvg] destination path required}"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

echo "[fetch-resvg] downloading resvg ${RESVG_VERSION}"
curl -fsSL -o "${tmp}/resvg.tar.gz" "${RESVG_URL}"

echo "[fetch-resvg] verifying sha256"
echo "${RESVG_SHA256}  ${tmp}/resvg.tar.gz" | sha256sum -c -

tar -xzf "${tmp}/resvg.tar.gz" -C "${tmp}" resvg
install -m 0755 "${tmp}/resvg" "${DEST}"
echo "[fetch-resvg] installed resvg -> ${DEST}"
