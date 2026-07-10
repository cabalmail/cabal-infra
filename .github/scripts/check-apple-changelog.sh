#!/usr/bin/env bash
#
# Require an `Apple:`-prefixed changelog fragment when a PR changes the Apple
# client sources.
#
# The TestFlight "What to Test" notes are built (by set-testflight-notes.py)
# from only the changelog entries prefixed `Apple:`, so an Apple client change
# that ships without such a fragment silently drops out of the notes testers
# read. This check is the enforcement half of that convention (see CLAUDE.md
# and changelog.d/README.md): if a PR touches the Apple client sources, it must
# add a changelog fragment whose entry begins `- Apple:`.
#
# It is a heuristic backstop, not a proof: a CI check cannot know whether a
# fragment truly describes the Apple change, only that a well-formed one exists.
# Some Apple-source PRs are legitimately not user-facing (refactors, test-only,
# CI, xcodegen). Apply the `no-changelog` PR label to opt those out.
#
# Runs from the apple-changelog.yml workflow on every pull_request event
# (including labeled/unlabeled). No path filter: this script self-gates by
# diffing the PR range and exits 0 early when no Apple client source changed.
#
# Required env:
#   BASE_SHA  PR base branch tip (github.event.pull_request.base.sha)
#   HEAD_SHA  PR head commit     (github.event.pull_request.head.sha)
# Optional env:
#   OPT_OUT   "true" when the PR carries the no-changelog label; skips the check

set -euo pipefail

: "${BASE_SHA:?missing BASE_SHA}"
: "${HEAD_SHA:?missing HEAD_SHA}"

# The Apple client sources whose changes warrant a tester-visible note. Scoped
# to shipped client code - not Tests/, project.yml, or apple/*.md - to keep the
# gate off PRs with no user-facing Apple surface. Keep in sync with the
# apple_src filter in lint.yml.
apple_src_re='^apple/(Cabalmail|CabalmailMac|CabalmailKit/Sources)/'

# Three-dot: changes on the PR head since it diverged from base, matching what
# dorny/paths-filter reports (ignores unrelated commits landed on base since).
changed="$(git diff --name-only "${BASE_SHA}...${HEAD_SHA}")"

apple_changed="$(printf '%s\n' "$changed" | grep -E "$apple_src_re" || true)"
if [ -z "$apple_changed" ]; then
  echo "[apple-changelog] No Apple client source changes; nothing to require."
  exit 0
fi

echo "[apple-changelog] Apple client sources changed:"
printf '%s\n' "$apple_changed" | sed 's/^/  /'

if [ "${OPT_OUT:-false}" = "true" ]; then
  echo "::notice::'no-changelog' label present; skipping the Apple changelog requirement."
  exit 0
fi

# Look for an added/modified changelog fragment whose first bullet is Apple:.
# The working tree is the PR merge checkout, so added fragments are present.
while IFS= read -r file; do
  case "$file" in
    changelog.d/*.md) ;;
    *) continue ;;
  esac
  [ "$file" = "changelog.d/README.md" ] && continue
  [ -f "$file" ] || continue  # deleted in the PR
  first_bullet="$(grep -m1 '^- ' "$file" || true)"
  if printf '%s' "$first_bullet" | grep -qE '^- Apple:'; then
    echo "[apple-changelog] Found Apple changelog fragment: $file"
    exit 0
  fi
done <<< "$changed"

echo "::error::Apple client sources changed but no 'Apple:'-prefixed changelog fragment was added."
cat >&2 <<'MSG'
Add a fragment changelog.d/<slug>.<category>.md whose entry begins with
"- Apple:" (e.g. "- Apple: **Threaded reader.** Messages now group ...").
The Apple: prefix scopes the entry into the TestFlight "What to Test" notes.

If this PR has no user-facing Apple-client change (refactor, test-only, CI),
apply the "no-changelog" label to the PR to opt out.
MSG
exit 1
