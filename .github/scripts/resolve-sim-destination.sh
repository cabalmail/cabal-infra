#!/usr/bin/env bash
#
# Create a simulator for one of apple.yml's simulator test jobs and emit its
# xcodebuild destination.
#
# Runner images ship simulator runtimes without devices created on them, so a
# bare `platform=iOS Simulator` destination cannot resolve ("Unable to find a
# destination..."). Each job creates a fresh device and tests against its
# UDID. select-sim-pair.jq chooses the runtime and device type together, from
# the runtime's own supportedDeviceTypes; its header explains the choice.
#
# Usage:
#   resolve-sim-destination.sh <family> <device-prefix> <simulator-name>
#     <family>          iOS or visionOS: the runtime name's first word, and the
#                       destination's platform
#     <device-prefix>   device type name prefix, e.g. "iPhone" or "Apple Vision"
#     <simulator-name>  name for the created device
#
# Writes `destination=platform=<family> Simulator,id=<udid>` to $GITHUB_OUTPUT.

set -euo pipefail

FAMILY="${1:?usage: resolve-sim-destination.sh <family> <device-prefix> <simulator-name>}"
PREFIX="${2:?usage: resolve-sim-destination.sh <family> <device-prefix> <simulator-name>}"
SIM_NAME="${3:?usage: resolve-sim-destination.sh <family> <device-prefix> <simulator-name>}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT must be set (GitHub Actions runner env)}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

xcrun simctl list runtimes --json > "$work/runtimes.json"
xcrun simctl list devicetypes --json > "$work/devicetypes.json"

# The image's runtimes and what each supports, so the log shows the inputs to
# the pick, including when the pick is a surprise rather than a failure.
echo "::group::[sim] installed $FAMILY runtimes"
jq -r --arg family "$FAMILY" --arg prefix "$PREFIX" '
  .runtimes[]
  | select(.name | startswith($family + " "))
  | [(.supportedDeviceTypes // [])[] | select(.name | startswith($prefix)) | .name] as $types
  | "\(.identifier) (\(.buildversion)) available=\(.isAvailable): \($types | length) \($prefix) types: "
    + ($types[:4] | join(", ")) + (if ($types | length) > 4 then ", ..." else "" end)
' "$work/runtimes.json"
echo "::endgroup::"

pair="$(jq -n -r \
  --slurpfile runtimes "$work/runtimes.json" \
  --slurpfile devicetypes "$work/devicetypes.json" \
  --arg family "$FAMILY" --arg prefix "$PREFIX" \
  -f "$here/select-sim-pair.jq")"
if [ -z "$pair" ]; then
  echo "::error::No available $FAMILY runtime supports a '$PREFIX' device type."
  xcrun simctl list runtimes
  xcrun simctl list devicetypes
  exit 1
fi
read -r RUNTIME_ID DEVICE_TYPE_ID <<< "$pair"

# Before `simctl create`, so a refused pair is named in the log.
echo "[sim] runtime:    $RUNTIME_ID"
echo "[sim] devicetype: $DEVICE_TYPE_ID"
UDID="$(xcrun simctl create "$SIM_NAME" "$DEVICE_TYPE_ID" "$RUNTIME_ID")"
echo "[sim] created $FAMILY simulator $UDID"
echo "destination=platform=$FAMILY Simulator,id=$UDID" >> "$GITHUB_OUTPUT"
