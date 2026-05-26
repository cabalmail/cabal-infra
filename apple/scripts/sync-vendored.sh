#!/usr/bin/env bash
#
# Materializes the vendored marked + turndown JS bundles (plus their MIT
# LICENSE files) into the CabalmailKit resource directory.
#
# Source of truth: react/admin/package.json — that's where the npm
# version pins live and where Dependabot opens bump PRs when CVEs land.
# The Apple composer needs the same bytes inside its WKWebView so it
# round-trips identically to the React composer; this script is how
# those bytes get there.
#
# Files produced (all gitignored; see apple/.gitignore):
#   apple/CabalmailKit/Sources/CabalmailKit/Compose/Resources/
#     marked.umd.js
#     turndown.js
#     marked-LICENSE.md
#     turndown-LICENSE
#
# Run this:
#   - After `git clone` before your first `swift test` / `xcodebuild`
#   - Any time react/admin/package.json's marked or turndown versions
#     change (`swift test` will fail with a missing-resource error if
#     you skip this and the destination dir is empty)
#   - CI runs it before every kit-test, app-build, and TestFlight job
#
# Requires: node + npm. Local devs who only touch the Apple kit and
# don't have node installed should `brew install node` once.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
REACT_DIR="$REPO_ROOT/react/admin"
DEST_DIR="$REPO_ROOT/apple/CabalmailKit/Sources/CabalmailKit/Compose/Resources"

if [ ! -d "$REACT_DIR" ]; then
    echo "error: react/admin not found at $REACT_DIR" >&2
    exit 1
fi

MARKED_SRC="$REACT_DIR/node_modules/marked/lib/marked.umd.js"
TURNDOWN_SRC="$REACT_DIR/node_modules/turndown/dist/turndown.js"
MARKED_LICENSE="$REACT_DIR/node_modules/marked/LICENSE.md"
TURNDOWN_LICENSE="$REACT_DIR/node_modules/turndown/LICENSE"

# Skip `npm ci` when every source file is already present — local
# `swift test` rebuild loops shouldn't pay the install cost on every
# run. CI starts cold and always installs. If you bumped marked or
# turndown in react/admin/package.json, delete the destination dir or
# `cd react/admin && npm ci` yourself before re-running this script.
NEED_INSTALL=0
for src in "$MARKED_SRC" "$TURNDOWN_SRC" "$MARKED_LICENSE" "$TURNDOWN_LICENSE"; do
    if [ ! -f "$src" ]; then
        NEED_INSTALL=1
        break
    fi
done

if [ "$NEED_INSTALL" -eq 1 ]; then
    if ! command -v npm >/dev/null 2>&1; then
        echo "error: npm not found on PATH. Install Node.js (e.g. 'brew install node')." >&2
        exit 1
    fi
    echo "[sync-vendored] react/admin/node_modules is incomplete; running 'npm ci'..."
    (cd "$REACT_DIR" && npm ci --no-audit --no-fund)
fi

mkdir -p "$DEST_DIR"
cp "$MARKED_SRC"      "$DEST_DIR/marked.umd.js"
cp "$TURNDOWN_SRC"    "$DEST_DIR/turndown.js"
cp "$MARKED_LICENSE"  "$DEST_DIR/marked-LICENSE.md"
cp "$TURNDOWN_LICENSE" "$DEST_DIR/turndown-LICENSE"

echo "[sync-vendored] Synced marked + turndown into $DEST_DIR"
