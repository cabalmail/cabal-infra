#!/bin/bash
# Build a sign-in-capable iOS Simulator app and install it on a simulator.
#
# The CI build recipe is deliberately NOT reused here: CI passes
# CODE_SIGNING_ALLOWED=NO, which strips entitlements, and sign-in then
# fails at runtime with keychain error -34018. Simulator ad-hoc signing
# (the default when nothing is overridden) is sufficient for a
# fully-working app. Do not try to repair an unsigned build afterwards
# with `codesign --entitlements` — that produces launch denials.
#
# ENABLE_DEBUG_DYLIB=NO: without it, the notification service
# extension's preview-dylib link step fails on a plain command-line
# build. ONLY_ACTIVE_ARCH=YES keeps the build quick.
#
# Usage:
#   scripts/build-sim.sh [device]
#
#   device — simulator name or UDID to install onto. Defaults to
#            "booted" (whatever simulator is currently booted).
#            Pass "-" to build without installing.
set -euo pipefail

cd "$(dirname "$0")/.."

DEVICE="${1:-booted}"
SCHEME=Cabalmail

log() { echo "[build-sim] $*"; }

command -v xcodegen >/dev/null 2>&1 || {
  log "xcodegen not found — install with: brew install xcodegen"
  exit 1
}

# Regenerating also materializes the gitignored marked/turndown web
# assets (preGenCommand) — without them the app builds but the compose
# editor's rich-text bridge never boots.
log "generating Xcode project"
xcodegen generate

XCODEBUILD_ARGS=(
  -workspace Cabalmail.xcworkspace
  -scheme "$SCHEME"
  -configuration Debug
  -destination "generic/platform=iOS Simulator"
  ONLY_ACTIVE_ARCH=YES
  ENABLE_DEBUG_DYLIB=NO
)

log "building $SCHEME for the iOS simulator"
xcodebuild "${XCODEBUILD_ARGS[@]}" build

# Resolve the built .app out of the default DerivedData location. Do NOT
# redirect DerivedData into the repo tree — if the repo lives under an
# iCloud-synced directory, codesign rejects the .app ("resource fork,
# Finder information, or similar detritus not allowed"); see docs/apple.md.
SETTINGS="$(xcodebuild "${XCODEBUILD_ARGS[@]}" -showBuildSettings build 2>/dev/null)"
APP_PATH="$(awk '
  /Build settings for action build and target Cabalmail:/ { in_target = 1 }
  in_target && sub(/^ *TARGET_BUILD_DIR = /, "")  { dir = $0 }
  in_target && sub(/^ *WRAPPER_NAME = /, "")      { name = $0 }
  dir != "" && name != "" { print dir "/" name; exit }
' <<<"$SETTINGS")"

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
  log "could not locate built app (looked for TARGET_BUILD_DIR/WRAPPER_NAME in build settings)"
  exit 1
fi
log "built $APP_PATH"

if [ "$DEVICE" = "-" ]; then
  log "skipping install (device '-')"
  exit 0
fi

log "installing onto simulator '$DEVICE'"
xcrun simctl install "$DEVICE" "$APP_PATH"
log "done — launch with: xcrun simctl launch $DEVICE com.cabalmail.Cabalmail"
