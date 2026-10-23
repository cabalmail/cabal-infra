# Pick a simulator runtime and device type that work together, for
# resolve-sim-destination.sh (apple.yml's simulator test jobs).
#
# Run as one command line:
#
#   jq -n -r -f select-sim-pair.jq --arg family iOS --arg prefix iPhone
#     --slurpfile runtimes    <(xcrun simctl list runtimes --json)
#     --slurpfile devicetypes <(xcrun simctl list devicetypes --json)
#
# Prints "<runtime id> <device type id>", or nothing when no available runtime
# of the family supports a device type whose name starts with the prefix.
#
# The pair comes from the runtime's own supportedDeviceTypes, so it is
# compatible by construction. A device type's min/max runtime versions are not
# enough: a device-specific launch runtime refuses device types that are in its
# version range. iOS 27.1 supports only the iPhone Duo
# (actions/runner-images#15000), and pairing it with iPhone 18 Pro made
# `simctl create` fail with "Incompatible device".
#
# Device type first, then runtime: walk the device types in simctl's own
# order, which leads with the newest flagship (iPhone 18 Pro on the Xcode 27
# images), take the first one an available runtime supports, and pair it with
# the newest runtime that supports it. Taking the newest runtime first
# would follow every device-specific launch runtime onto its one new device,
# so PRs would test on the iPhone Duo until a universal 27.2 runtime ships.
# Device first keeps the test device stable, and still moves to a newer
# runtime as soon as one supports it.

($runtimes[0].runtimes
  | map(select(.isAvailable and (.name | startswith($family + " "))))
  | sort_by(.version | split(".") | map(tonumber))
  | reverse) as $candidates
| first(
    $devicetypes[0].devicetypes[]
    | select(.name | startswith($prefix))
    | .identifier as $type
    | first($candidates[] | select(any((.supportedDeviceTypes // [])[]; .identifier == $type)))
    | "\(.identifier) \($type)"
  ) // empty
