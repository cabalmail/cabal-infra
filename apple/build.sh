#!/usr/bin/env bash
#
# Local build/lint/test helper for the Apple client. Mirrors the invocations
# in .github/workflows/apple.yml so a local "does it build?" check matches CI
# instead of being hand-assembled each time (and drifting).
#
# Usage:
#   ./build.sh                 # generate + lint + build all platforms (default)
#   ./build.sh lint            # swiftlint --strict only
#   ./build.sh macos|ios|visionos
#   ./build.sh kit-test        # xcodebuild test for CabalmailKit
#   ./build.sh all             # lint + macos + ios + visionos
#   ./build.sh generate        # xcodegen generate only
#
# The .xcodeproj is generated (not committed), so every target runs
# `xcodegen generate` first. swiftlint and xcodebuild both need full Xcode
# selected (`xcode-select -s /Applications/Xcode.app/...`), not the Command
# Line Tools; set DEVELOPER_DIR to override per-invocation if needed.
#
# Two flags exist for local Apple-Silicon builds that CI doesn't need:
#   - ONLY_ACTIVE_ARCH=YES: the app target otherwise builds universal
#     (arm64 + x86_64) while the local CabalmailKit SwiftPM package produces
#     only the active arch -> "could not find module 'CabalmailKit' for target
#     'x86_64-apple-macos'". Harmless for the arm64-only device builds.
#   - a repo-local DerivedData dir: avoids a stale/incompatible cached
#     CabalmailKit.swiftmodule in the shared ~/Library DerivedData.

set -euo pipefail

cd "$(dirname "$0")"

readonly WORKSPACE="Cabalmail.xcworkspace"
readonly DERIVED_DATA="${DERIVED_DATA:-$PWD/.derivedData}"
readonly COMMON_FLAGS=(
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  ONLY_ACTIVE_ARCH=YES
)

log() { printf '[build] %s\n' "$*"; }

# Pipe xcodebuild through xcbeautify when present; otherwise pass raw so the
# script works on a box that doesn't have it (xcbeautify isn't required).
run_xcodebuild() {
  if command -v xcbeautify >/dev/null 2>&1; then
    xcodebuild "$@" | xcbeautify
  else
    xcodebuild "$@"
  fi
}

generate() {
  log "xcodegen generate"
  xcodegen generate
}

lint() {
  log "swiftlint --strict"
  swiftlint lint --strict --quiet
}

build_scheme() {
  local scheme="$1" destination="$2"
  log "build $scheme ($destination)"
  run_xcodebuild build \
    -workspace "$WORKSPACE" \
    -scheme "$scheme" \
    -destination "$destination" \
    -derivedDataPath "$DERIVED_DATA" \
    "${COMMON_FLAGS[@]}"
}

macos()    { build_scheme CabalmailMac 'platform=macOS'; }
ios()      { build_scheme Cabalmail    'generic/platform=iOS'; }
visionos() { build_scheme Cabalmail    'generic/platform=visionOS'; }

kit_test() {
  log "test CabalmailKit (macOS)"
  run_xcodebuild test \
    -scheme CabalmailKit \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    "${COMMON_FLAGS[@]}"
}

main() {
  local target="${1:-all}"
  case "$target" in
    generate) generate ;;
    lint)     generate; lint ;;
    macos)    generate; macos ;;
    ios)      generate; ios ;;
    visionos) generate; visionos ;;
    kit-test) generate; kit_test ;;
    all)      generate; lint; macos; ios; visionos ;;
    *) echo "usage: $0 [generate|lint|macos|ios|visionos|kit-test|all]" >&2; exit 2 ;;
  esac
  log "done: $target"
}

main "$@"
