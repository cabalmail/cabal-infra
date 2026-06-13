#!/usr/bin/env bash
#
# Build and upload every lambda/api/<func>.zip in parallel. The
# per-function logic lives in build-api-one.sh; this driver just
# enumerates dirs and dispatches them under xargs -P.
#
# Per-function deps and helper.py are bundled into each function zip
# at build time (see docs/0.9.x/lambda-layer-removal-plan.md); the
# canonical helper.py source lives at lambda/api/_shared/helper.py
# and is copied into each consuming function's zip by build-api-one.sh.
# Directories whose names start with "_" are scaffolding for this
# bundling (currently just _shared/) and are not built as Lambda
# functions. Determinism still matters because each function zip's
# sha256 is recorded as source_code_hash on the running Lambda; a
# spurious hash bump would force every CI run to redeploy code that
# is byte-equivalent to what is already deployed.
#
# Sources of non-determinism we control here:
#   - SOURCE_DATE_EPOCH: honored by zip, pip wheel builds, and most
#     reproducible-build tooling.
#   - --no-compile: stops pip from generating .pyc files, whose binary
#     headers contain magic numbers that vary across Python builds.
#   - PYTHONDONTWRITEBYTECODE=1: belt-and-braces against any import
#     during install that might trigger compilation.
#   - __pycache__/*.pyc purge: removes anything pip compiled despite
#     the flags above.
#   - direct_url.json purge: pip writes this per-package and it
#     records the wheel's source URL, which differs between cache hits
#     and cache misses.
#   - chmod normalisation: ensures the zip's external-attribute field
#     is identical regardless of what umask the runner started with.
#   - LC_ALL=C sort: locale-stable filename ordering inside the zip.
#   - touch -h: sets every entry's mtime to SOURCE_DATE_EPOCH without
#     following symlinks.

set -euo pipefail

cd ./lambda/api

JOBS="${BUILD_JOBS:-8}"

# Resolve the deploy account once and pass it to every parallel child so
# each s3 upload can verify --expected-bucket-owner without making its own
# sts call. The deploy_lambda profile is configured by app.yml before this
# runs; fall back to a per-child lookup if it is somehow unset.
export EXPECTED_BUCKET_OWNER="${EXPECTED_BUCKET_OWNER:-$(aws sts get-caller-identity --profile deploy_lambda --query Account --output text)}"

funcs=()
for FUNC in */ ; do
  FUNC="${FUNC%/}"
  [ -d "${FUNC}" ] || continue
  case "${FUNC}" in
    _*) continue ;;
  esac
  funcs+=("${FUNC}")
done

if [ "${#funcs[@]}" -eq 0 ]; then
  echo "[build-api] no function dirs under lambda/api/"
  exit 0
fi

printf '%s\n' "${funcs[@]}" | LC_ALL=C sort | xargs -P "${JOBS}" -I {} ../../.github/scripts/build-api-one.sh {}
