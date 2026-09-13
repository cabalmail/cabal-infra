#!/usr/bin/env bash
#
# Materializes the vendored Readability.js (plus its license) into the
# Android app's assets for the feed reader's article view (rss plan,
# phase 6d), the same way apple/scripts/sync-vendored.sh does for
# CabalmailKit. Source of truth: react/admin/package.json, where the
# @mozilla/readability pin lives and where dependabot bumps it.
#
# Files produced (gitignored; see android/.gitignore):
#   android/app/src/main/assets/reader/Readability.js
#   android/app/src/main/assets/reader/readability-LICENSE.md
#
# Run this after `git clone` before a build whose article view should
# offer the reader toggle; a build without the asset still works, the
# toggle is simply absent. CI runs it before every gradle invocation.
#
# Requires: node + npm when react/admin/node_modules is not populated.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
REACT_DIR="$REPO_ROOT/react/admin"
DEST_DIR="$REPO_ROOT/android/app/src/main/assets/reader"

READABILITY_SRC="$REACT_DIR/node_modules/@mozilla/readability/Readability.js"
READABILITY_LICENSE="$REACT_DIR/node_modules/@mozilla/readability/LICENSE.md"

if [ ! -f "$READABILITY_SRC" ] || [ ! -f "$READABILITY_LICENSE" ]; then
    if ! command -v npm >/dev/null 2>&1; then
        echo "error: npm not found on PATH. Install Node.js (e.g. 'brew install node')." >&2
        exit 1
    fi
    echo "[sync-vendored] react/admin/node_modules is incomplete; running 'npm ci'..."
    (cd "$REACT_DIR" && npm ci --no-audit --no-fund)
fi

mkdir -p "$DEST_DIR"
cp "$READABILITY_SRC"     "$DEST_DIR/Readability.js"
cp "$READABILITY_LICENSE" "$DEST_DIR/readability-LICENSE.md"
echo "[sync-vendored] Synced Readability.js into $DEST_DIR"
