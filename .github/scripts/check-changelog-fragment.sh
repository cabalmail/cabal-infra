#!/usr/bin/env bash
#
# Require a changelog fragment on every PR that changes anything beyond
# documentation.
#
# The changelog is the engineering record of the system, not only the
# user-facing release notes: refactors, CI work, and infrastructure changes
# belong in it too. Every PR must therefore add (or edit) a fragment under
# changelog.d/ unless it touches only documentation. The Apple:/Android:
# prefixes are a separate, narrower concern - routing entries into the tester
# release notes - enforced by check-client-changelog.sh; the `no-changelog`
# label waives only that prefix, never the fragment this check requires.
#
# Documentation-only PRs are exempt: every changed file is a Markdown file,
# lives under docs/, or is the LICENSE. (Fragments are Markdown too, so a PR
# that only reworks pending fragments is also exempt.)
#
# Two structural exemptions:
#   - Release PRs (stage -> main): promote has already collated the pending
#     fragments into CHANGELOG.md and deleted them, and the PR's base...head
#     diff is the whole release, so requiring a surviving fragment would
#     always fail. Identified by base ref `main` + head ref `stage`.
#   - Dependabot PRs: dependabot cannot write fragments. Dependency bumps are
#     recorded by the lockfile diff and git history instead.
#
# As a side benefit, any added or edited file under changelog.d/ must be a
# well-formed fragment name (<slug>.<category>.md with a category the collator
# knows), so a typo fails at PR time instead of at release time.
#
# Runs from .github/workflows/changelog.yml on every pull_request event. No
# path filter: the doc-only exemption is decided here from the PR diff, so
# the check reports a definite pass/fail rather than a skip.
#
# Required env:
#   BASE_SHA   PR base branch tip (github.event.pull_request.base.sha)
#   HEAD_SHA   PR head commit     (github.event.pull_request.head.sha)
#   BASE_REF   PR base branch name
#   HEAD_REF   PR head branch name
#   PR_AUTHOR  PR author login (github.event.pull_request.user.login)

set -euo pipefail

: "${BASE_SHA:?missing BASE_SHA}"
: "${HEAD_SHA:?missing HEAD_SHA}"
: "${BASE_REF:?missing BASE_REF}"
: "${HEAD_REF:?missing HEAD_REF}"
: "${PR_AUTHOR:?missing PR_AUTHOR}"

tag="changelog-fragment"

if [ "$BASE_REF" = "main" ] && [ "$HEAD_REF" = "stage" ]; then
  echo "[$tag] Release PR (stage -> main): fragments are already collated into CHANGELOG.md. Skipping."
  exit 0
fi

if [ "$PR_AUTHOR" = "dependabot[bot]" ]; then
  echo "[$tag] Dependabot PR: dependency bumps are recorded by the lockfile diff. Skipping."
  exit 0
fi

# Three-dot: changes on the PR head since it diverged from base, matching what
# the client changelog gates diff (ignores unrelated commits landed on base).
changed="$(git diff --name-only "${BASE_SHA}...${HEAD_SHA}")"

nondoc="$(printf '%s\n' "$changed" | grep -Ev '(\.md$|^docs/|^LICENSE$)' || true)"
if [ -z "$nondoc" ]; then
  echo "[$tag] Documentation-only PR; no fragment required."
  exit 0
fi

echo "[$tag] Non-documentation changes:"
printf '%s\n' "$nondoc" | sed 's/^/  /'

# Look for an added or edited fragment, and reject malformed fragment names.
# The working tree is the PR merge checkout, so surviving fragments are
# present; a deletion alone (e.g. retracting an entry) is not a fragment.
found=""
bad=""
while IFS= read -r file; do
  case "$file" in
    changelog.d/*) ;;
    *) continue ;;
  esac
  [ "$file" = "changelog.d/README.md" ] && continue
  [ -f "$file" ] || continue  # deleted in the PR
  case "$file" in
    changelog.d/*.added.md|changelog.d/*.changed.md|changelog.d/*.deprecated.md|changelog.d/*.removed.md|changelog.d/*.fixed.md|changelog.d/*.security.md)
      echo "[$tag] Found changelog fragment: $file"
      found=1
      ;;
    *)
      echo "::error::Malformed fragment name '$file': expected changelog.d/<slug>.<category>.md with <category> one of added/changed/deprecated/removed/fixed/security."
      bad=1
      ;;
  esac
done <<< "$changed"

if [ -n "$bad" ]; then
  exit 1
fi
if [ -n "$found" ]; then
  exit 0
fi

echo "::error::This PR changes more than documentation but adds no changelog fragment."
cat >&2 <<'MSG'
Every change gets a changelog fragment - the changelog records engineering
history, not only user-facing release notes. Add a file
changelog.d/<slug>.<category>.md (category: added/changed/deprecated/removed/
fixed/security); see changelog.d/README.md for the format.

If this PR iterates on an unreleased change that already has a pending
fragment, update that fragment in place - an edit satisfies this check; do
not add a second file for the same change.

The `no-changelog` label does not waive this check. It only waives the
Apple:/Android: prefix in the client changelog gates, which routes an entry
out of the tester release notes; the (unprefixed) fragment is still required.
MSG
exit 1
