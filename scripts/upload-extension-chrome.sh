#!/usr/bin/env bash
#
# Upload a packaged Chrome extension to the Chrome Web Store and (optionally)
# publish it.
#
# Authentication is an OAuth refresh token for the Chrome Web Store API,
# minted once against a Google Cloud project that has the API enabled. The
# four values below are the same ones CI keeps as repository secrets:
#
#   CHROME_WEBSTORE_EXTENSION_ID      the listing's store-assigned item ID
#   CHROME_WEBSTORE_CLIENT_ID         OAuth client ID
#   CHROME_WEBSTORE_CLIENT_SECRET     OAuth client secret
#   CHROME_WEBSTORE_REFRESH_TOKEN     refresh token for the
#                                     .../auth/chromewebstore scope
#
# The very first upload of a listing cannot go through this script: a new item
# must be created by hand in the developer console, which is what assigns the
# item ID. Every upload after that is this script.
#
# Usage:
#   upload-extension-chrome.sh [options]
#     -z, --zip <file>     package to upload (default: the newest
#                          extensions/build/cabalmail-chrome-*.zip)
#     -t, --target <default|trustedTesters>
#                          publish after uploading. "trustedTesters" goes to
#                          the tester group only; "default" goes public and
#                          enters review. Omit to upload as a draft.
#     -n, --dry-run        check credentials and the package, change nothing
#     -h, --help
#
# Exit status is non-zero if the store reports any item-level error, including
# the soft "uploaded but not published" states the API reports with HTTP 200.

set -euo pipefail

LOG_TAG="[upload-extension-chrome]"
log() { echo "${LOG_TAG} $*"; }
die() { echo "${LOG_TAG} error: $*" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() { sed -n '3,/^# Exit status/p' "${BASH_SOURCE[0]}" | sed 's/^#\{0,1\} \{0,1\}//'; }

ZIP=""
TARGET=""
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    -z|--zip)    ZIP="${2:?--zip needs a value}"; shift 2 ;;
    -t|--target) TARGET="${2:?--target needs a value}"; shift 2 ;;
    -n|--dry-run) DRY_RUN=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           die "unknown argument: $1 (try --help)" ;;
  esac
done

if [ -n "${TARGET}" ] && [ "${TARGET}" != "default" ] && [ "${TARGET}" != "trustedTesters" ]; then
  die "--target must be default or trustedTesters"
fi

for var in CHROME_WEBSTORE_EXTENSION_ID CHROME_WEBSTORE_CLIENT_ID \
           CHROME_WEBSTORE_CLIENT_SECRET CHROME_WEBSTORE_REFRESH_TOKEN; do
  eval "value=\${${var}:-}"
  [ -n "${value}" ] || die "${var} is not set"
done

if [ -z "${ZIP}" ]; then
  # Newest by mtime; the build script writes one zip per version.
  ZIP="$(ls -t "${ROOT}"/extensions/build/cabalmail-chrome-*.zip 2>/dev/null | head -1 || true)"
  [ -n "${ZIP}" ] || die "no package found; run scripts/build-extension.sh --store first"
fi
[ -f "${ZIP}" ] || die "no such package: ${ZIP}"

# A package built without EXTENSION_STORE_BUILD still carries the manifest
# key, which the store rejects with an opaque error. Catch it here instead.
command -v unzip >/dev/null 2>&1 || die "unzip not found"
packaged_manifest="$(unzip -p "${ZIP}" manifest.json)"
if [[ "${packaged_manifest}" == *'"key"'* ]]; then
  die "${ZIP} carries a manifest key; rebuild with scripts/build-extension.sh --store"
fi

# Extract one field from a JSON document on stdin, or fail loudly.
json_field() {
  python3 -c 'import json,sys; d=json.load(sys.stdin); v=d
for k in sys.argv[1].split("."):
    v = v.get(k) if isinstance(v, dict) else None
print(v if v is not None else "")' "$1"
}

log "package: ${ZIP}"
log "item:    ${CHROME_WEBSTORE_EXTENSION_ID}"

log "exchanging refresh token"
token_response="$(curl -sS -X POST 'https://oauth2.googleapis.com/token' \
  -d "client_id=${CHROME_WEBSTORE_CLIENT_ID}" \
  -d "client_secret=${CHROME_WEBSTORE_CLIENT_SECRET}" \
  -d "refresh_token=${CHROME_WEBSTORE_REFRESH_TOKEN}" \
  -d 'grant_type=refresh_token')"
ACCESS_TOKEN="$(printf '%s' "${token_response}" | json_field access_token)"
if [ -z "${ACCESS_TOKEN}" ]; then
  die "token exchange failed: $(printf '%s' "${token_response}" | head -c 500)"
fi

if [ "${DRY_RUN}" -eq 1 ]; then
  log "dry run: credentials valid and package looks uploadable; stopping"
  exit 0
fi

log "uploading"
upload_response="$(curl -sS -X PUT \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H 'x-goog-api-version: 2' \
  -T "${ZIP}" \
  "https://www.googleapis.com/upload/chromewebstore/v1.1/items/${CHROME_WEBSTORE_EXTENSION_ID}")"
upload_state="$(printf '%s' "${upload_response}" | json_field uploadState)"
if [ "${upload_state}" != "SUCCESS" ]; then
  die "upload finished in state '${upload_state:-unknown}': $(printf '%s' "${upload_response}" | head -c 1000)"
fi
log "upload succeeded"

if [ -z "${TARGET}" ]; then
  log "left as a draft (no --target given)"
  exit 0
fi

log "publishing to ${TARGET}"
publish_response="$(curl -sS -X POST \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H 'x-goog-api-version: 2' \
  -H 'Content-Length: 0' \
  "https://www.googleapis.com/chromewebstore/v1.1/items/${CHROME_WEBSTORE_EXTENSION_ID}/publish?publishTarget=${TARGET}")"
if [[ "${publish_response}" == *'"itemError"'* ]]; then
  die "publish reported errors: $(printf '%s' "${publish_response}" | head -c 1000)"
fi
log "publish accepted: $(printf '%s' "${publish_response}" | head -c 300)"
log "done"
