#!/usr/bin/env bash
#
# Cut a release from the stage branch: collate the pending changelog.d/
# fragments into a dated CHANGELOG.md section, commit on stage, push, and open
# the stage -> main PR. Stops before merge - merging to the protected main
# branch (prod) stays a deliberate manual step.
#
# This is the operator's release trigger; it is run by a human in their shell,
# not by CI. CI never calls it.
#
# Usage:
#   promote.sh <version|patch|minor|major> [--yes] [--no-push] [--date YYYY-MM-DD]
#
#   <version>   explicit semver (e.g. 0.10.14), or a bump keyword
#               (patch/minor/major) computed from the latest git tag
#   --yes       skip the confirmation prompt before committing/pushing
#   --no-push   collate + commit locally only; do not push or open a PR
#   --date      release date override (default: today, UTC)

set -euo pipefail

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; }

[ $# -ge 1 ] || { usage; exit 1; }

SPEC=""; ASSUME_YES=0; NO_PUSH=0; DATE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --yes)     ASSUME_YES=1 ;;
    --no-push) NO_PUSH=1 ;;
    --date)    DATE="${2:?--date needs a value}"; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)        echo "[promote] ERROR: unknown flag $1" >&2; usage; exit 1 ;;
    *)         [ -z "${SPEC}" ] || { echo "[promote] ERROR: unexpected argument '$1'" >&2; exit 1; }
               SPEC="$1" ;;
  esac
  shift
done
[ -n "${SPEC}" ] || { usage; exit 1; }

ROOT="$(git rev-parse --show-toplevel)"
cd "${ROOT}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "[promote] $*"; }
die() { echo "[promote] ERROR: $*" >&2; exit 1; }

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "${BRANCH}" = "stage" ] || die "must be on 'stage' (on '${BRANCH}'); releases are cut from stage"
git diff --quiet && git diff --cached --quiet \
  || die "working tree not clean; commit or stash before releasing"

# Refresh tags from origin so the bump computation and the reuse guard below see
# versions already released by CI: release.yml tags on origin (via gh), not
# locally, so a stale checkout would otherwise miss them. Best-effort - a fetch
# failure (offline, no origin) must not block a release; the guard then falls
# back to local + gh state.
git fetch --tags --quiet origin 2>/dev/null \
  || log "WARNING: could not fetch tags from origin; reuse check uses local/gh state only"

# Resolve the version: explicit semver, or a bump from the latest semver tag.
latest_tag() { git tag --sort=-v:refname | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | head -1; }
case "${SPEC}" in
  patch|minor|major)
    base="$(latest_tag)"; [ -n "${base}" ] || die "no semver tag to bump from; pass an explicit version"
    IFS=. read -r MA MI PA <<<"${base}"
    case "${SPEC}" in
      patch) PA=$((PA + 1)) ;;
      minor) MI=$((MI + 1)); PA=0 ;;
      major) MA=$((MA + 1)); MI=0; PA=0 ;;
    esac
    VERSION="${MA}.${MI}.${PA}"
    log "bump ${SPEC}: ${base} -> ${VERSION}"
    ;;
  *)
    [[ "${SPEC}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+].+)?$ ]] \
      || die "'${SPEC}' is not a semver version or a bump keyword (patch/minor/major)"
    VERSION="${SPEC}"
    ;;
esac
# Refuse to reuse a version. After the fetch above, the local tag check covers
# anything CI tagged on origin; the gh release check is an authoritative
# cross-check when gh is available (collate-changelog.sh adds a third guard
# against a duplicate CHANGELOG.md section).
git rev-parse "refs/tags/${VERSION}" >/dev/null 2>&1 \
  && die "version ${VERSION} is already tagged"
if command -v gh >/dev/null 2>&1 && gh release view "${VERSION}" >/dev/null 2>&1; then
  die "version ${VERSION} already has a GitHub release"
fi

# Fold fragments into a dated section (stages CHANGELOG.md + fragment deletions).
"${SCRIPT_DIR}/collate-changelog.sh" "${VERSION}" ${DATE:+"${DATE}"}

echo
log "staged for release ${VERSION}:"
git --no-pager diff --cached --stat
echo
git --no-pager diff --cached -- CHANGELOG.md | sed -n '1,40p'
echo

if [ "${ASSUME_YES}" -ne 1 ]; then
  if [ "${NO_PUSH}" -eq 1 ]; then
    printf '[promote] commit release %s on stage (local only)? [y/N] ' "${VERSION}"
  else
    printf '[promote] commit release %s on stage, push, and open a PR to main? [y/N] ' "${VERSION}"
  fi
  read -r reply || true
  case "${reply}" in
    y|Y|yes|YES) ;;
    *)
      # Undo the collation so a declined release leaves the tree exactly as it
      # was. The pre-collate tree was clean (checked above) and nothing has been
      # committed or pushed yet, so restoring these two paths to HEAD reverts the
      # CHANGELOG.md edit and recreates the git-rm'd fragments.
      git checkout -q HEAD -- CHANGELOG.md changelog.d
      log "aborted; reverted the collated changes (fragments and CHANGELOG.md restored)."
      exit 0
      ;;
  esac
fi

git commit -m "Set release date for version ${VERSION}"

if [ "${NO_PUSH}" -eq 1 ]; then
  log "committed locally (no push). Push stage and open the stage->main PR when ready."
  exit 0
fi

git push origin stage

command -v gh >/dev/null 2>&1 \
  || { log "pushed stage. gh CLI not found - open the stage->main PR manually."; exit 0; }

existing="$(gh pr list --base main --head stage --state open --json url --jq '.[0].url // empty' 2>/dev/null || true)"
if [ -n "${existing}" ]; then
  pr_url="${existing}"
  log "stage->main PR already open: ${pr_url}"
else
  pr_url="$(gh pr create --base main --head stage \
    --title "Release ${VERSION}" \
    --body "Promote stage to prod for ${VERSION}. See CHANGELOG.md.")" \
    || die "gh pr create failed"
  log "opened PR: ${pr_url}"
fi

# Wait for checks, then report the real outcome. A just-created PR usually has
# NO checks registered for a few seconds (the same replication lag that delays
# the PR appearing in the web UI). In that window `gh pr checks` returns
# immediately - which we previously mistook for "checks failed". So first wait
# for checks to APPEAR (poll until the "no checks reported" state clears), then
# watch them to completion and branch on gh's documented exit codes
# (0 = pass, 1 = fail, 8 = pending). Check status is advisory: the human reviews
# and merges, so a failing/unknown result never fails this script.
log "waiting for checks to register on ${pr_url} (can lag a few seconds after PR creation)..."
appeared=0
deadline=$(( $(date +%s) + 180 ))
while [ "$(date +%s)" -lt "${deadline}" ]; do
  out="$(gh pr checks "${pr_url}" 2>&1)" || true
  printf '%s' "${out}" | grep -qi 'no checks' || { appeared=1; break; }
  sleep 6
done

if [ "${appeared}" -ne 1 ]; then
  log "no checks registered within the wait window - review on GitHub: ${pr_url}"
else
  log "watching checks (Ctrl-C stops watching; the PR stays open)..."
  rc=0
  gh pr checks "${pr_url}" --watch --interval 10 || rc=$?
  case "${rc}" in
    0) log "all checks passed." ;;
    1) log "some checks FAILED - review before merging." ;;
    8) log "checks still pending - review on GitHub." ;;
    *) log "could not determine check status (gh exit ${rc}) - review on GitHub." ;;
  esac
fi

log "done. Review and merge to promote to prod: ${pr_url}"
