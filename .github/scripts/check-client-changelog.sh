#!/usr/bin/env bash
#
# Require a client-prefixed changelog fragment when a PR changes a native
# client's shipped sources.
#
# Each native client's tester-facing release notes are built from only the
# changelog entries carrying that client's prefix - `Apple:` feeds the
# TestFlight "What to Test" notes (set-testflight-notes.py), `Android:` feeds
# the Play Console release notes (play-release-notes.py) - so a client change
# that ships without such a fragment silently drops out of the notes testers
# read. This check is the enforcement half of that convention (see CLAUDE.md
# and changelog.d/README.md): if a PR touches the client's sources, it must add
# a changelog fragment whose entry begins `- <Prefix>:`.
#
# It is a heuristic backstop, not a proof: a CI check cannot know whether a
# fragment truly describes the client change, only that a well-formed one
# exists. Some client-source PRs are legitimately not user-facing (refactors,
# test-only, CI, project generation). Apply the `no-changelog` PR label to opt
# those out.
#
# Runs from the apple-changelog.yml / android-changelog.yml workflows on every
# pull_request event (including labeled/unlabeled). No path filter: this script
# self-gates by diffing the PR range and exits 0 early when none of the client's
# sources changed.
#
# Usage:
#   check-client-changelog.sh <Prefix> <source-regex>
#     <Prefix>        the entry prefix without the colon, e.g. Apple or Android
#     <source-regex>  extended regex matching the client's shipped source paths
#
# Required env:
#   BASE_SHA  PR base branch tip (github.event.pull_request.base.sha)
#   HEAD_SHA  PR head commit     (github.event.pull_request.head.sha)
# Optional env:
#   OPT_OUT   "true" when the PR carries the no-changelog label; skips the check

set -euo pipefail

PREFIX="${1:?usage: check-client-changelog.sh <Prefix> <source-regex>}"
SRC_RE="${2:?usage: check-client-changelog.sh <Prefix> <source-regex>}"
: "${BASE_SHA:?missing BASE_SHA}"
: "${HEAD_SHA:?missing HEAD_SHA}"

tag="$(printf '%s' "$PREFIX" | tr '[:upper:]' '[:lower:]')-changelog"

# Three-dot: changes on the PR head since it diverged from base, matching what
# dorny/paths-filter reports (ignores unrelated commits landed on base since).
changed="$(git diff --name-only "${BASE_SHA}...${HEAD_SHA}")"

client_changed="$(printf '%s\n' "$changed" | grep -E "$SRC_RE" || true)"
if [ -z "$client_changed" ]; then
  echo "[$tag] No $PREFIX client source changes; nothing to require."
  exit 0
fi

echo "[$tag] $PREFIX client sources changed:"
printf '%s\n' "$client_changed" | sed 's/^/  /'

if [ "${OPT_OUT:-false}" = "true" ]; then
  echo "::notice::'no-changelog' label present; skipping the $PREFIX changelog requirement."
  exit 0
fi

# Look for an added/modified changelog fragment whose first bullet carries the
# prefix. The working tree is the PR merge checkout, so added fragments are
# present.
while IFS= read -r file; do
  case "$file" in
    changelog.d/*.md) ;;
    *) continue ;;
  esac
  [ "$file" = "changelog.d/README.md" ] && continue
  [ -f "$file" ] || continue  # deleted in the PR
  first_bullet="$(grep -m1 '^- ' "$file" || true)"
  if printf '%s' "$first_bullet" | grep -qE "^- ${PREFIX}:"; then
    echo "[$tag] Found $PREFIX changelog fragment: $file"
    exit 0
  fi
done <<< "$changed"

# Release PRs (stage -> main) carry no fragments: collate-changelog.sh has
# already folded them into CHANGELOG.md and deleted the fragment files, so the
# base...head diff shows the collated CHANGELOG.md gaining the entries and no
# surviving changelog.d/*.md. Accept a prefixed line added to CHANGELOG.md as
# equivalent to a fragment - the notes scripts read the collated CHANGELOG.md.
if git diff "${BASE_SHA}...${HEAD_SHA}" -- CHANGELOG.md \
     | grep -qE "^\+- ${PREFIX}:"; then
  echo "[$tag] Found $PREFIX entry added to CHANGELOG.md (release PR)."
  exit 0
fi

echo "::error::$PREFIX client sources changed but no '$PREFIX:'-prefixed changelog fragment was added."
cat >&2 <<MSG
Add a fragment changelog.d/<slug>.<category>.md whose entry begins with
"- ${PREFIX}:" (e.g. "- ${PREFIX}: **Threaded reader.** Messages now group ...").
The ${PREFIX}: prefix scopes the entry into the ${PREFIX} testers' release notes.

If this PR has no user-facing ${PREFIX}-client change (refactor, test-only, CI),
apply the "no-changelog" label to the PR to opt out.
MSG
exit 1
