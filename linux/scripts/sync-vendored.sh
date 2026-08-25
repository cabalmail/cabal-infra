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
# apple/scripts/sync-vendored.sh and deliberately works the same way, except
# that it verifies an existing node_modules against the lockfile before
# trusting it (see the NEED_INSTALL block).
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
#   - Any time react/admin/package-lock.json's marked or turndown versions
#     change — the script notices a stale node_modules and reinstalls, so a
#     bump does not need any manual cleanup here
#
# Note makepkg does *not* run this: PKGBUILD fetches the upstream npm tarballs
# as pinned source=() entries instead, because prepare() must not reach the
# network and npm is not a makedepend. See Phase 2 of
# docs/1.x/linux-client-plan.md.
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

LOCKFILE="$REACT_DIR/package-lock.json"

# The version `npm ci` would install. The lockfile, not package.json, is the
# comparison: package.json carries a caret range, and the range is still
# satisfied by the version a Dependabot bump replaced.
locked_version() {
    node -e 'const lock = require(process.argv[1]);
             const entry = (lock.packages || {})["node_modules/" + process.argv[2]];
             process.stdout.write((entry && entry.version) || "");' \
        "$LOCKFILE" "$1" 2>/dev/null || true
}

# The version actually sitting in node_modules.
installed_version() {
    local manifest="$REACT_DIR/node_modules/$1/package.json"
    [ -f "$manifest" ] || return 0
    node -e 'process.stdout.write(require(process.argv[1]).version || "");' \
        "$manifest" 2>/dev/null || true
}

# Skip `npm ci` when every source file is present *and* at the locked version —
# a local rebuild loop shouldn't pay the install cost on every run, but a stale
# tree must never be vendored silently. That is the whole point of pinning in
# one place: when a bump lands (CVE or otherwise), the next run reinstalls
# rather than copying the version the bump replaced. CI starts cold and always
# installs.
NEED_INSTALL=0
for src in "$MARKED_SRC" "$TURNDOWN_SRC" "$MARKED_LICENSE" "$TURNDOWN_LICENSE"; do
    if [ ! -f "$src" ]; then
        NEED_INSTALL=1
        break
    fi
done

if [ "$NEED_INSTALL" -eq 0 ]; then
    if ! command -v node >/dev/null 2>&1; then
        echo "[sync-vendored] error: node not found on PATH; cannot confirm the vendored versions match $LOCKFILE. Install Node.js (e.g. 'pacman -S nodejs npm')." >&2
        exit 1
    fi
    for package in marked turndown; do
        locked="$(locked_version "$package")"
        installed="$(installed_version "$package")"
        if [ -z "$locked" ] || [ "$installed" != "$locked" ]; then
            echo "[sync-vendored] $package ${installed:-(absent)} does not match the lockfile's ${locked:-(unknown)}; reinstalling."
            NEED_INSTALL=1
        fi
    done
fi

if [ "$NEED_INSTALL" -eq 1 ]; then
    if ! command -v npm >/dev/null 2>&1; then
        echo "[sync-vendored] error: npm not found on PATH. Install Node.js (e.g. 'pacman -S nodejs npm')." >&2
        exit 1
    fi
    echo "[sync-vendored] installing react/admin dependencies with 'npm ci'..."
    (cd "$REACT_DIR" && npm ci --no-audit --no-fund)
fi

mkdir -p "$DEST_DIR"
cp "$MARKED_SRC"       "$DEST_DIR/marked.umd.js"
cp "$TURNDOWN_SRC"     "$DEST_DIR/turndown.js"
cp "$MARKED_LICENSE"   "$DEST_DIR/marked-LICENSE.md"
cp "$TURNDOWN_LICENSE" "$DEST_DIR/turndown-LICENSE"

echo "[sync-vendored] Synced marked + turndown into $DEST_DIR"
