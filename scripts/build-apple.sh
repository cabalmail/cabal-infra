#!/usr/bin/env bash
#
# Local build/lint/test helper for the Apple client. Mirrors the pull-request
# jobs in .github/workflows/apple.yml - the swiftlint gate, kit-test's macOS
# leg, app-test, ios-app-test, and every platform app-build builds - so a
# local "does it build?" check matches CI instead of being hand-assembled each
# time (and drifting). The signed upload jobs that run on pushes are not
# mirrored.
#
# Lives in scripts/ (not apple/) on purpose: a script under apple/ would trip
# apple.yml's `apple/**` path filter and kick off a full Apple CI build on
# every edit. It operates on the apple/ tree by cd-ing there below.
#
# Usage (from the repo root):
#   scripts/build-apple.sh              # generate + lint + build all platforms (default)
#   scripts/build-apple.sh lint         # swiftlint --strict only
#   scripts/build-apple.sh macos|ios|visionos|watchos
#   scripts/build-apple.sh kit-test     # xcodebuild test for CabalmailKit (macOS)
#   scripts/build-apple.sh app-test     # app-layer tests, macOS-hosted (CabalmailMac scheme)
#   scripts/build-apple.sh ios-app-test # app-layer tests, iOS-hosted (Cabalmail scheme)
#   scripts/build-apple.sh test         # kit-test + app-test + ios-app-test
#   scripts/build-apple.sh all          # lint + macos + ios + visionos + watchos
#   scripts/build-apple.sh generate     # xcodegen generate only
#
# app-test launches Cabalmail.app as its test host, so it needs a logged-in
# GUI session. ios-app-test runs on the simulator named by
# IOS_TEST_DESTINATION (default: 'platform=iOS Simulator,name=iPhone 17');
# CI creates a fresh device instead.
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

# This script lives in scripts/; everything below runs against the apple/ tree.
cd "$(dirname "$0")/../apple"

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
watchos()  { build_scheme CabalmailWatch 'generic/platform=watchOS'; }

kit_test() {
  log "test CabalmailKit (macOS)"
  # Run from the SwiftPM package dir (apple/CabalmailKit) so xcodebuild
  # resolves the package's auto-synthesized CabalmailKit scheme, which has
  # a test action. Run from apple/ instead and the same scheme name resolves
  # to the xcodegen-generated project's build-only CabalmailKit scheme,
  # failing with "Scheme CabalmailKit is not currently configured for the
  # test action". Mirrors apple.yml's macOS test leg (working-directory:
  # apple/CabalmailKit), including -skipPackagePluginValidation.
  ( cd CabalmailKit && run_xcodebuild test \
      -scheme CabalmailKit \
      -destination 'platform=macOS' \
      -skipPackagePluginValidation \
      -test-timeouts-enabled YES \
      -default-test-execution-time-allowance 180 \
      -derivedDataPath "$DERIVED_DATA" \
      "${COMMON_FLAGS[@]}" )
}

# The app-layer suites (apple/CabalmailTests and apple/CabalmailiOSTests),
# which `swift test` never compiles. Same flags as apple.yml's app-test and
# ios-app-test jobs.
test_scheme() {
  local scheme="$1" destination="$2"
  log "test $scheme ($destination)"
  run_xcodebuild test \
    -workspace "$WORKSPACE" \
    -scheme "$scheme" \
    -destination "$destination" \
    -skipPackagePluginValidation \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 180 \
    -derivedDataPath "$DERIVED_DATA" \
    "${COMMON_FLAGS[@]}" \
    CODE_SIGN_IDENTITY=""
}

app_test()     { test_scheme CabalmailMac 'platform=macOS'; }
ios_app_test() { test_scheme Cabalmail "${IOS_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17}"; }

main() {
  local target="${1:-all}"
  case "$target" in
    generate)     generate ;;
    lint)         generate; lint ;;
    macos)        generate; macos ;;
    ios)          generate; ios ;;
    visionos)     generate; visionos ;;
    watchos)      generate; watchos ;;
    kit-test)     kit_test ;;
    app-test)     generate; app_test ;;
    ios-app-test) generate; ios_app_test ;;
    test)         generate; kit_test; app_test; ios_app_test ;;
    all)          generate; lint; macos; ios; visionos; watchos ;;
    *) echo "usage: $0 [generate|lint|macos|ios|visionos|watchos|kit-test|app-test|ios-app-test|test|all]" >&2; exit 2 ;;
  esac
  log "done: $target"
}

main "$@"
