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
# test-only, CI, project generation). Apply the `no-changelog` PR label to
# waive the prefix for those - the entry then stays out of the tester notes.
# The label waives only the prefix: the PR still needs an unprefixed fragment,
# enforced by check-changelog-fragment.sh (the repo-wide changelog gate).
#
# Release PRs (stage -> main) are exempt, as they are from
# check-changelog-fragment.sh: every change in a release already passed this
# gate on its own PR into stage, promote has collated the fragments away, and
# the base...head diff is the whole release. Identified by base ref `main` +
# head ref `stage`. The exemption is structural rather than the `no-changelog`
# label on purpose: a label is added after the PR opens, the `labeled` event
# starts a second run that cancels the first, and the cancelled check run
# stays on the head commit, where the release dashboard counts it as failing.
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
#   BASE_REF  PR base branch name } together they identify a release PR
#   HEAD_REF  PR head branch name } (main <- stage), which is skipped

set -euo pipefail

PREFIX="${1:?usage: check-client-changelog.sh <Prefix> <source-regex>}"
SRC_RE="${2:?usage: check-client-changelog.sh <Prefix> <source-regex>}"
: "${BASE_SHA:?missing BASE_SHA}"
: "${HEAD_SHA:?missing HEAD_SHA}"

tag="$(printf '%s' "$PREFIX" | tr '[:upper:]' '[:lower:]')-changelog"

if [ "${BASE_REF:-}" = "main" ] && [ "${HEAD_REF:-}" = "stage" ]; then
  echo "[$tag] Release PR (stage -> main): every change in it passed this gate on its way into stage. Skipping."
  exit 0
fi

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
  echo "::notice::'no-changelog' label present; waiving the $PREFIX: prefix requirement. An unprefixed fragment is still required by the changelog-fragment gate."
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

echo "::error::$PREFIX client sources changed but no '$PREFIX:'-prefixed changelog fragment was added."
cat >&2 <<MSG
Add a fragment changelog.d/<slug>.<category>.md whose entry begins with
"- ${PREFIX}:" (e.g. "- ${PREFIX}: **Threaded reader.** Messages now group ...").
The ${PREFIX}: prefix scopes the entry into the ${PREFIX} testers' release notes.

If this PR has no user-facing ${PREFIX}-client change (refactor, test-only, CI),
apply the "no-changelog" label: it waives this prefix requirement, keeping the
entry out of the tester notes. The PR still needs an unprefixed fragment to
satisfy the repo-wide changelog-fragment gate.
MSG
exit 1
