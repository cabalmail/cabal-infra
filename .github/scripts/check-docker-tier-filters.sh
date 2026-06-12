#!/usr/bin/env bash
#
# Guard against per-tier filter drift in app.yml. Phase 1 of
# docs/0.10.x/per-tier-docker-deploy-plan.md.
#
# The docker job builds only the tiers whose inputs changed, where
# "inputs" are encoded as dorny/paths-filter globs under the filter
# key docker_<tier> ('-' in the tier name maps to '_'). If a
# Dockerfile gains a COPY/ADD of a file under docker/ that its tier's
# filter does not cover, changes to that file would silently skip the
# rebuild of a tier that depends on it. This script parses every
# docker/*/Dockerfile, extracts the build-context paths it consumes
# (the build context is docker/ - see the docker job's buildx
# invocation), and fails if any consumed path is not matched by the
# tier's filter globs, or if a tier directory has no filter key at
# all.
#
# Run from the repository root (CI does, in app.yml's setup job).
#
# Known limitations - acceptable for this repo's Dockerfiles, revisit
# if they stop holding:
#   - COPY/ADD instructions split across line continuations are not
#     parsed.
#   - Glob sources (COPY foo/*) are checked by their literal prefix.
#   - Filter globs are matched with shell `case` semantics, where '*'
#     crosses '/' boundaries (dorny's picomatch is stricter for a
#     single '*'); the filters only use '**' and exact paths, where
#     the two agree.
#   - The per-tier filter lists in app.yml must not contain comment
#     lines: the parser treats any non-list line as the end of a
#     tier's block.

set -euo pipefail

WORKFLOW="${WORKFLOW:-.github/workflows/app.yml}"
DOCKER_DIR="${DOCKER_DIR:-docker}"

status=0

# Print the glob list of filter key $1 in $WORKFLOW, one per line,
# quotes stripped.
filter_paths() {
  local key="$1"
  awk -v key="${key}:" '
    $1 == key { in_block = 1; next }
    in_block && $1 == "-" { print $2; next }
    in_block { exit }
  ' "${WORKFLOW}" | tr -d "'\""
}

# Does path $1 match any of the newline-separated glob patterns in $2?
matches_any() {
  local path="$1" patterns="$2" pattern
  while IFS= read -r pattern; do
    [ -n "${pattern}" ] || continue
    pattern="${pattern//\*\*/*}"
    # shellcheck disable=SC2254  # unquoted on purpose: glob match
    case "${path}" in
      ${pattern}) return 0 ;;
    esac
  done <<<"${patterns}"
  return 1
}

found_any=0
for dockerfile in "${DOCKER_DIR}"/*/Dockerfile; do
  [ -f "${dockerfile}" ] || continue
  found_any=1
  tier="$(basename "$(dirname "${dockerfile}")")"
  key="docker_${tier//-/_}"

  patterns="$(filter_paths "${key}")"
  if [ -z "${patterns}" ]; then
    echo "FAIL: ${WORKFLOW} has no '${key}' filter for ${dockerfile}"
    status=1
    continue
  fi

  # Build-context sources of COPY/ADD instructions. --from= copies
  # come from an earlier build stage, not the context, so they are
  # skipped; other --flags (--chown, --chmod) are dropped; the last
  # remaining token is the destination.
  sources="$(awk '
    toupper($1) == "COPY" || toupper($1) == "ADD" {
      from = 0
      for (i = 2; i <= NF; i++) if ($i ~ /^--from=/) from = 1
      if (from) next
      n = 0
      for (i = 2; i <= NF; i++) { if ($i ~ /^--/) continue; field[++n] = $i }
      for (i = 1; i < n; i++) print field[i]
    }
  ' "${dockerfile}")"

  while IFS= read -r src; do
    [ -n "${src}" ] || continue
    case "${src}" in
      http://*|https://*) continue ;; # ADD from URL: not in the build context
    esac
    path="${DOCKER_DIR}/${src}"
    case "${path}" in
      *[\*\?\[]*)
        # Glob source: test a representative file under its literal
        # prefix instead of the pattern itself.
        path="${path%%[\*\?\[]*}x"
        ;;
    esac
    if ! matches_any "${path}" "${patterns}"; then
      echo "FAIL: ${dockerfile} consumes ${DOCKER_DIR}/${src} but the '${key}' filter in ${WORKFLOW} does not cover it"
      status=1
    fi
  done <<<"${sources}"
done

if [ "${found_any}" -eq 0 ]; then
  echo "FAIL: no ${DOCKER_DIR}/*/Dockerfile found - is the working directory the repository root?"
  exit 1
fi

if [ "${status}" -eq 0 ]; then
  echo "OK: every docker/*/Dockerfile build input is covered by its tier's filter in ${WORKFLOW}"
fi
exit "${status}"
