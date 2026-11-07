#!/usr/bin/env bash
#
# Build the iOS app and launch it on a simulator, from a cold start.
#
# Finds (or creates) a simulator of the requested device type on the newest
# installed iOS runtime, boots it, opens the simulator window, builds and
# installs a sign-in-capable app with apple/scripts/build-sim.sh, and
# launches it. Defaults to the iPhone Duo, the one device that runs the
# `#available(iOS 27.1, *)` code paths.
#
# Lives in scripts/ (not apple/) for the same reason build-apple.sh does:
# an edit under apple/ trips apple.yml's path filter.
#
# Usage (from the repo root, or via `make apple-sim`):
#   scripts/run-sim.sh                  # iPhone Duo
#   scripts/run-sim.sh "iPhone 17 Pro"  # any device type name simctl knows
#   make apple-sim DEVICE="iPad Pro 13-inch (M5)"
#
# The created simulator is named after its device type, so later runs reuse
# it (and its keychain, so you stay signed in). It builds the current
# working tree; check out the branch you want first.
#
# Needs full Xcode, xcodegen, node/npm (for the vendored web assets), and an
# iOS simulator runtime. Without a runtime the script stops and names the
# install command.

set -euo pipefail

readonly DEVICE_TYPE="${1:-iPhone Duo}"
readonly BUNDLE_ID="com.cabalmail.Cabalmail"

log() { printf '[run-sim] %s\n' "$*"; }
die() { log "$*"; exit 1; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v xcrun >/dev/null 2>&1 || die "xcrun not found - install Xcode"

# Pick the device type id and the newest available iOS runtime that supports
# it, plus the UDID of an existing simulator with the same name on that
# runtime (empty if there is none yet). python3 ships with the Xcode CLT.
read -r TYPE_ID RUNTIME_ID UDID < <(
  xcrun simctl list --json | python3 -I -c '
import json, sys
name = sys.argv[1]
data = json.load(sys.stdin)
types = [t for t in data["devicetypes"] if t["name"] == name]
if not types:
    sys.exit("no device type named %r (see: xcrun simctl list devicetypes)" % name)
type_id = types[0]["identifier"]
runtimes = [
    r for r in data["runtimes"]
    if r.get("platform") == "iOS" and r.get("isAvailable")
    and any(t["identifier"] == type_id for t in r.get("supportedDeviceTypes", []))
]
if not runtimes:
    print(type_id, "-", "-")
    sys.exit(0)
runtime = max(runtimes, key=lambda r: [int(p) for p in r["version"].split(".")])
existing = [
    d for d in data["devices"].get(runtime["identifier"], [])
    if d["name"] == name and d.get("isAvailable")
]
print(type_id, runtime["identifier"], existing[0]["udid"] if existing else "-")
' "$DEVICE_TYPE"
) || die "could not resolve a simulator for '$DEVICE_TYPE'"

if [ "$RUNTIME_ID" = "-" ]; then
  die "no installed iOS runtime supports '$DEVICE_TYPE'. Install one with:
    xcodebuild -downloadPlatform iOS
  (or Xcode > Settings > Components), then rerun."
fi

if [ "$UDID" = "-" ]; then
  log "creating '$DEVICE_TYPE' simulator on $RUNTIME_ID"
  UDID="$(xcrun simctl create "$DEVICE_TYPE" "$TYPE_ID" "$RUNTIME_ID")"
fi
log "using '$DEVICE_TYPE' ($UDID)"

# `bootstatus -b` boots the device if needed and waits until it is ready.
xcrun simctl bootstatus "$UDID" -b >/dev/null

# Bring up a window to touch. Xcode 27 replaced Simulator.app with DeviceHub;
# try both so the script works on either side of that change.
open -b com.apple.iphonesimulator --args -CurrentDeviceUDID "$UDID" 2>/dev/null \
  || open -b com.apple.dt.Devices 2>/dev/null \
  || log "could not open a simulator window; the device is booted regardless"

"$repo_root/apple/scripts/build-sim.sh" "$UDID"

log "launching $BUNDLE_ID"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl launch "$UDID" "$BUNDLE_ID"
