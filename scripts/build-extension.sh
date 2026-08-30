#!/usr/bin/env bash
#
# Build the browser-extension bundles.
#
# Two variants come out of the same sources:
#
#   dev    - what you load unpacked while developing. Keeps the manifest
#            "key", which pins the Chrome extension ID (and therefore the
#            OAuth redirect URI) to the same value on every machine.
#   store  - what you upload to the Chrome Web Store. Strips the "key":
#            the Web Store rejects a new-item upload that carries one and
#            assigns the listing its own permanent ID instead.
#
# The control domain is the only value baked in at build time; everything
# else is fetched at runtime from https://admin.<control-domain>/config.json.
#
# Usage:
#   build-extension.sh [options]
#     -d, --control-domain <domain>  control domain to bake in
#                                    (default: $CABALMAIL_CONTROL_DOMAIN)
#     -b, --browser <chrome|safari|both>   default: both
#     -s, --store                    strip the manifest key and, for chrome,
#                                    write an upload-ready zip
#     -r, --report-url <url>         where the popup's "report wrong
#                                    detection" link files issues
#                                    (default: $CABALMAIL_REPORT_URL, else
#                                    the upstream tracker)
#     -v, --version <semver>         manifest version (default: the newest
#                                    release in CHANGELOG.md)
#     -o, --out <dir>                where to write the store zip
#                                    (default: extensions/build)
#     -h, --help
#
# Output:
#   extensions/chrome/dist/                              (chrome bundle)
#   extensions/safari/CabalmailExtension/Resources/      (safari bundle)
#   extensions/build/cabalmail-chrome-<version>.zip      (--store, chrome)

set -euo pipefail

LOG_TAG="[build-extension]"
log() { echo "${LOG_TAG} $*"; }
die() { echo "${LOG_TAG} error: $*" >&2; exit 1; }

usage() {
  sed -n '3,/^# Output:/p' "${BASH_SOURCE[0]}" | sed 's/^#\{0,1\} \{0,1\}//'
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXT_DIR="${ROOT}/extensions"

CONTROL_DOMAIN="${CABALMAIL_CONTROL_DOMAIN:-}"
REPORT_URL="${CABALMAIL_REPORT_URL:-}"
BROWSER="both"
STORE=0
VERSION="${EXTENSION_VERSION:-}"
OUT_DIR="${EXT_DIR}/build"

while [ $# -gt 0 ]; do
  case "$1" in
    -d|--control-domain) CONTROL_DOMAIN="${2:?--control-domain needs a value}"; shift 2 ;;
    -b|--browser)        BROWSER="${2:?--browser needs a value}"; shift 2 ;;
    -s|--store)          STORE=1; shift ;;
    -r|--report-url)     REPORT_URL="${2:?--report-url needs a value}"; shift 2 ;;
    -v|--version)        VERSION="${2:?--version needs a value}"; shift 2 ;;
    -o|--out)            OUT_DIR="${2:?--out needs a value}"; shift 2 ;;
    -h|--help)           usage; exit 0 ;;
    *)                   die "unknown argument: $1 (try --help)" ;;
  esac
done

case "${BROWSER}" in
  chrome|safari|both) ;;
  *) die "--browser must be chrome, safari, or both" ;;
esac

command -v node >/dev/null 2>&1 || die "node not found (need Node 20.19+ or 22.12+)"
command -v npm  >/dev/null 2>&1 || die "npm not found"

if [ -z "${CONTROL_DOMAIN}" ]; then
  # The build orchestrator's own placeholder. It produces a loadable bundle
  # whose config fetch points nowhere, which is only ever useful for a
  # compile check.
  log "warning: no control domain given; building against the cabalmail.example placeholder"
  log "warning: the resulting bundle cannot reach any environment"
else
  export CABALMAIL_CONTROL_DOMAIN="${CONTROL_DOMAIN}"
fi
if [ -n "${REPORT_URL}" ]; then export CABALMAIL_REPORT_URL="${REPORT_URL}"; fi
if [ -n "${VERSION}" ]; then export EXTENSION_VERSION="${VERSION}"; fi
if [ "${STORE}" -eq 1 ]; then export EXTENSION_STORE_BUILD=1; fi

if [ ! -d "${EXT_DIR}/node_modules" ]; then
  log "installing workspace dependencies"
  (cd "${EXT_DIR}" && npm ci)
fi

variant=$([ "${STORE}" -eq 1 ] && echo store || echo dev)
log "building ${BROWSER} (${variant}) for ${CONTROL_DOMAIN:-cabalmail.example}"

if [ "${BROWSER}" = "chrome" ] || [ "${BROWSER}" = "both" ]; then
  (cd "${EXT_DIR}" && npm run build --workspace chrome)
fi
if [ "${BROWSER}" = "safari" ] || [ "${BROWSER}" = "both" ]; then
  (cd "${EXT_DIR}" && npm run build --workspace safari)
fi

if [ "${STORE}" -eq 1 ] && { [ "${BROWSER}" = "chrome" ] || [ "${BROWSER}" = "both" ]; }; then
  command -v zip >/dev/null 2>&1 || die "zip not found (needed for --store)"
  dist="${EXT_DIR}/chrome/dist"
  built_version="$(node -e "process.stdout.write(require('${dist}/manifest.json').version)")"
  if grep -q '"key"' "${dist}/manifest.json"; then
    die "store build still carries a manifest key; the Web Store would reject it"
  fi
  mkdir -p "${OUT_DIR}"
  zipfile="${OUT_DIR}/cabalmail-chrome-${built_version}.zip"
  rm -f "${zipfile}"
  (cd "${dist}" && zip -qr "${zipfile}" .)
  log "wrote ${zipfile}"
fi

log "done"
