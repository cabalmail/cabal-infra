#!/usr/bin/env bash
#
# Materializes the vendored marked + turndown JS bundles (plus their MIT
# LICENSE files) into the Linux composer's resource directory.
#
# Source of truth: react/admin/package.json — that's where the npm version
# pins live and where Dependabot opens bump PRs when CVEs land. The Linux
# composer needs the same bytes inside its WebKitGTK view as the React and
# Apple composers have, so Markdown round-trips identically across all three;
# this script is how those bytes get there. It is the sibling of
# apple/scripts/sync-vendored.sh and deliberately works the same way.
#
# Files produced (all gitignored; see linux/.gitignore):
#   linux/cabalmail-gtk/resources/editor/
#     marked.umd.js
#     turndown.js
#     marked-LICENSE.md
#     turndown-LICENSE
#
# Run this:
#   - Via `cargo xtask sync-vendored`, which is the documented spelling
#   - After `git clone`, before building the composer (Phase 5 onward)
#   - Any time react/admin/package.json's marked or turndown versions change
#
# Note makepkg does *not* run this: PKGBUILD fetches the upstream npm tarballs
# as pinned source=() entries instead, because prepare() must not reach the
# network and npm is not a makedepend. See Phase 2 of
# docs/1.1.x/linux-client-plan.md.
#
# Requires: node + npm.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
LINUX_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
REPO_ROOT="$( cd "$LINUX_DIR/.." && pwd )"
REACT_DIR="$REPO_ROOT/react/admin"
DEST_DIR="$LINUX_DIR/cabalmail-gtk/resources/editor"

if [ ! -d "$REACT_DIR" ]; then
    echo "[sync-vendored] error: react/admin not found at $REACT_DIR" >&2
    exit 1
fi

MARKED_SRC="$REACT_DIR/node_modules/marked/lib/marked.umd.js"
TURNDOWN_SRC="$REACT_DIR/node_modules/turndown/dist/turndown.js"
MARKED_LICENSE="$REACT_DIR/node_modules/marked/LICENSE.md"
TURNDOWN_LICENSE="$REACT_DIR/node_modules/turndown/LICENSE"

# Skip `npm ci` when every source file is already present — a local rebuild
# loop shouldn't pay the install cost on every run. CI starts cold and always
# installs. If you bumped marked or turndown in react/admin/package.json,
# delete the destination directory or run `npm ci` in react/admin yourself
# before re-running this script.
NEED_INSTALL=0
for src in "$MARKED_SRC" "$TURNDOWN_SRC" "$MARKED_LICENSE" "$TURNDOWN_LICENSE"; do
    if [ ! -f "$src" ]; then
        NEED_INSTALL=1
        break
    fi
done

if [ "$NEED_INSTALL" -eq 1 ]; then
    if ! command -v npm >/dev/null 2>&1; then
        echo "[sync-vendored] error: npm not found on PATH. Install Node.js (e.g. 'pacman -S nodejs npm')." >&2
        exit 1
    fi
    echo "[sync-vendored] react/admin/node_modules is incomplete; running 'npm ci'..."
    (cd "$REACT_DIR" && npm ci --no-audit --no-fund)
fi

mkdir -p "$DEST_DIR"
cp "$MARKED_SRC"       "$DEST_DIR/marked.umd.js"
cp "$TURNDOWN_SRC"     "$DEST_DIR/turndown.js"
cp "$MARKED_LICENSE"   "$DEST_DIR/marked-LICENSE.md"
cp "$TURNDOWN_LICENSE" "$DEST_DIR/turndown-LICENSE"

echo "[sync-vendored] Synced marked + turndown into $DEST_DIR"
