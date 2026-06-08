#!/usr/bin/env bash
#
# Collate pending changelog fragments from changelog.d/ into a new dated
# release section at the top of CHANGELOG.md, then remove the consumed
# fragments.
#
# Why fragments: multiple in-flight branches / Claude Code sessions used to edit
# the same "## [Unreleased]" block of CHANGELOG.md, which produced merge
# conflicts and forced manual renumbering whenever a release landed in between.
# A fragment is a standalone file under changelog.d/, so concurrent work never
# touches CHANGELOG.md and never needs to know the target version - at release
# time every pending fragment rolls into the new section automatically.
#
# Fragment files are named  <slug>.<category>.md  where <category> is one of the
# Keep a Changelog sections (added, changed, deprecated, removed, fixed,
# security). The file body is the entry exactly as it should appear under that
# section, including the leading "- " and any continuation-line indentation; the
# collator groups fragments by category and concatenates them verbatim, so the
# hand-wrapped house style is preserved. changelog.d/README.md is ignored.
#
# Usage:
#   collate-changelog.sh <version> [date]
#     <version>  semver string for the release, e.g. 0.10.14
#     [date]     ISO date (default: today, UTC), e.g. 2026-06-10
#
# On success CHANGELOG.md gains the new section, the fragment files are deleted,
# and the result is staged (git rm / git add) when inside a work tree. Exits
# non-zero with no changes if there are no fragments or a fragment names an
# unknown category.

set -euo pipefail

VERSION="${1:?usage: collate-changelog.sh <version> [date]}"
DATE="${2:-$(date -u +%F)}"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CHANGELOG="${ROOT}/CHANGELOG.md"
FRAG_DIR="${ROOT}/changelog.d"

log() { echo "[collate-changelog] $*"; }
die() { echo "[collate-changelog] ERROR: $*" >&2; exit 1; }

# Canonical Keep a Changelog section order. heading_for maps a category to its
# display heading (and rejects unknown ones). A case statement rather than an
# associative array so this runs on macOS's stock bash 3.2.
CATEGORIES=(added changed deprecated removed fixed security)
heading_for() {
  case "$1" in
    added)      echo "Added" ;;
    changed)    echo "Changed" ;;
    deprecated) echo "Deprecated" ;;
    removed)    echo "Removed" ;;
    fixed)      echo "Fixed" ;;
    security)   echo "Security" ;;
    *)          return 1 ;;
  esac
}

[ -f "${CHANGELOG}" ] || die "no CHANGELOG.md at ${CHANGELOG}"
[ -d "${FRAG_DIR}" ]  || die "no changelog.d/ at ${FRAG_DIR}"
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+].+)?$ ]] \
  || die "version '${VERSION}' is not semver (expected X.Y.Z)"

# Collect fragments (everything but the README).
shopt -s nullglob
all_fragments=()
for f in "${FRAG_DIR}"/*.md; do
  [ "$(basename "${f}")" = "README.md" ] && continue
  all_fragments+=("${f}")
done
shopt -u nullglob
[ "${#all_fragments[@]}" -gt 0 ] || die "no fragments in changelog.d/ - nothing to release"

# Validate every category up front, so a typo fails before anything is written.
for f in "${all_fragments[@]}"; do
  base="$(basename "${f}")"; stem="${base%.md}"; cat="${stem##*.}"
  heading_for "${cat}" >/dev/null \
    || die "fragment '${base}' has unknown category '${cat}' (expected one of: ${CATEGORIES[*]})"
done

section="$(mktemp)"; rebuilt="$(mktemp)"
trap 'rm -f "${section}" "${rebuilt}"' EXIT

# Build the new section: header, then each non-empty category in canonical
# order with its fragments concatenated verbatim (one fragment = one bullet).
{
  printf '## [%s] - %s\n' "${VERSION}" "${DATE}"
  for cat in "${CATEGORIES[@]}"; do
    shopt -s nullglob
    matches=( "${FRAG_DIR}"/*."${cat}".md )
    shopt -u nullglob
    [ "${#matches[@]}" -gt 0 ] || continue
    printf '\n### %s\n' "$(heading_for "${cat}")"
    for f in "${matches[@]}"; do
      # Command substitution trims trailing newlines; printf restores exactly
      # one, so fragments abut cleanly whether or not they end in a newline.
      printf '%s\n' "$(cat "${f}")"
    done
  done
} > "${section}"

# Insert the section immediately above the first existing "## [" release
# header (newest on top). If the changelog has no release sections yet, append.
awk -v secfile="${section}" '
  BEGIN { sec = ""; while ((getline line < secfile) > 0) sec = sec line "\n" }
  /^## \[/ && !done { printf "%s\n", sec; done = 1 }
  { print }
  END { if (!done) printf "\n%s", sec }
' "${CHANGELOG}" > "${rebuilt}"

mv "${rebuilt}" "${CHANGELOG}"

# Stage the result: git rm the consumed fragments, git add the changelog.
# Outside a work tree (e.g. a test sandbox) just delete the files.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git rm --quiet "${all_fragments[@]}"
  git add "${CHANGELOG}"
else
  rm -f "${all_fragments[@]}"
fi

log "released ${VERSION} (${DATE}): folded ${#all_fragments[@]} fragment(s) into CHANGELOG.md"
