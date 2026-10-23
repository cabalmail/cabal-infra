"""Tests for .github/scripts/select-sim-pair.jq.

apple.yml's simulator test jobs create their own device, and the runtime and
device type they pass to `simctl create` come from this jq program (via
resolve-sim-destination.sh). These pin the policy against `simctl list
--json` shaped fixtures: the pair is always one the runtime itself supports,
the device type is chosen first and the newest runtime supporting it second,
and unavailable or other-family runtimes are ignored.

The fixture `XCODE_27_2_IMAGE` mirrors the xcode-27-arm64 image 20261022.0305,
where the 2026-10-22 failure happened: iOS 27.0 supports the regular iPhones
and iOS 27.1 supports only the iPhone Duo. `OldIndependentPick` re-runs the
selection the workflow used before (newest runtime, first iPhone device type,
chosen separately) against it, to show the fixture really produces the pair
`simctl create` refused.

Needs `jq` on PATH (preinstalled on the GitHub runners). Run in CI by
`.github/workflows/scripts-tests.yml`. Run by hand from the repo root:

    python3 scripts/tests/test_select_sim_pair.py
"""

import json
import os
import shutil
import subprocess
import tempfile
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PROGRAM = os.path.join(REPO_ROOT, ".github", "scripts", "select-sim-pair.jq")

RUNTIME = "com.apple.CoreSimulator.SimRuntime."
DEVICE = "com.apple.CoreSimulator.SimDeviceType."


def device_type(name):
    """A `simctl list devicetypes` entry; the identifier follows Apple's pattern."""
    return {"name": name, "identifier": DEVICE + name.replace(" ", "-")}


def runtime(family, version, supports, available=True, ident_family=None):
    """A `simctl list runtimes` entry supporting the named device types."""
    ident = "%s-%s" % (ident_family or family, version.replace(".", "-"))
    return {
        "name": "%s %s" % (family, version),
        "version": version,
        "identifier": RUNTIME + ident,
        "isAvailable": available,
        "supportedDeviceTypes": [device_type(n) for n in supports],
    }


# simctl's own device type order: newest flagship first.
IPHONES = ["iPhone 18 Pro", "iPhone 18 Pro Max", "iPhone 17 Pro", "iPhone 17", "iPhone Air"]
DEVICE_TYPES = IPHONES + ["iPhone Duo", "iPad Pro 13-inch (M5)", "Apple Vision Pro"]

# The universal runtimes every Xcode 27 image carries.
UNIVERSAL = [
    runtime("iOS", "27.0", IPHONES + ["iPad Pro 13-inch (M5)"]),
    runtime("visionOS", "27.0", ["Apple Vision Pro"], ident_family="xrOS"),
]
XCODE_27_2_IMAGE = UNIVERSAL + [runtime("iOS", "27.1", ["iPhone Duo"])]


def run_jq(program, runtimes, devicetypes, *args, program_file=True):
    """Run a jq program over fixture `simctl list` JSON; return stdout lines."""
    jq = shutil.which("jq")
    if jq is None:
        raise AssertionError("jq is not on PATH; these tests drive the real jq program")
    with tempfile.TemporaryDirectory() as tmp:
        rt = os.path.join(tmp, "runtimes.json")
        dt = os.path.join(tmp, "devicetypes.json")
        with open(rt, "w", encoding="utf-8") as f:
            json.dump({"runtimes": runtimes}, f)
        with open(dt, "w", encoding="utf-8") as f:
            json.dump({"devicetypes": [device_type(n) for n in devicetypes]}, f)
        cmd = [jq, "-n", "-r", "--slurpfile", "runtimes", rt, "--slurpfile", "devicetypes", dt, *args]
        cmd += ["-f", program] if program_file else [program]
        out = subprocess.run(cmd, check=True, capture_output=True, text=True).stdout
    return [line for line in out.splitlines() if line]


class SelectSimPairTests(unittest.TestCase):
    """The pair select-sim-pair.jq prints, for a family and device prefix."""

    def pick(self, runtimes, devicetypes=None, family="iOS", prefix="iPhone"):
        """Return (runtime, device type) short names, asserting compatibility."""
        lines = run_jq(PROGRAM, runtimes, DEVICE_TYPES if devicetypes is None else devicetypes,
                       "--arg", "family", family, "--arg", "prefix", prefix)
        if not lines:
            return None
        self.assertEqual(len(lines), 1, lines)
        runtime_id, type_id = lines[0].split(" ")
        chosen = next(r for r in runtimes if r["identifier"] == runtime_id)
        self.assertIn(type_id, [t["identifier"] for t in chosen["supportedDeviceTypes"]],
                      "picked a device type its runtime does not support")
        return runtime_id[len(RUNTIME):], type_id[len(DEVICE):]

    def test_device_specific_runtime_is_passed_over(self):
        self.assertEqual(self.pick(XCODE_27_2_IMAGE), ("iOS-27-0", "iPhone-18-Pro"))

    def test_universal_newer_runtime_is_taken(self):
        runtimes = XCODE_27_2_IMAGE + [runtime("iOS", "27.2", IPHONES + ["iPhone Duo"])]
        self.assertEqual(self.pick(runtimes), ("iOS-27-2", "iPhone-18-Pro"))

    def test_unavailable_runtime_is_ignored(self):
        runtimes = UNIVERSAL + [runtime("iOS", "27.2", IPHONES, available=False)]
        self.assertEqual(self.pick(runtimes), ("iOS-27-0", "iPhone-18-Pro"))

    def test_device_type_no_runtime_supports_is_skipped(self):
        # A newer Xcode's device profiles can list a model whose runtime is
        # not installed; the next device type in order is used instead.
        self.assertEqual(self.pick(UNIVERSAL, ["iPhone 19 Pro"] + DEVICE_TYPES),
                         ("iOS-27-0", "iPhone-18-Pro"))

    def test_device_specific_device_listed_first_gets_its_own_runtime(self):
        # The cost of device-first: if simctl ever orders the niche device
        # first, that device and its runtime are used. Still a pair simctl
        # accepts, never the refused one.
        self.assertEqual(self.pick(XCODE_27_2_IMAGE, ["iPhone Duo"] + DEVICE_TYPES),
                         ("iOS-27-1", "iPhone-Duo"))

    def test_versions_compare_numerically(self):
        runtimes = [runtime("iOS", "27.9", IPHONES), runtime("iOS", "27.10", IPHONES)]
        self.assertEqual(self.pick(runtimes), ("iOS-27-10", "iPhone-18-Pro"))

    def test_visionos_family_and_prefix(self):
        self.assertEqual(self.pick(UNIVERSAL, family="visionOS", prefix="Apple Vision"),
                         ("xrOS-27-0", "Apple-Vision-Pro"))

    def test_family_prefix_does_not_match_a_longer_family_name(self):
        # "iOS " with the space: an "iOSLike 30.0" runtime is not iOS.
        runtimes = UNIVERSAL + [runtime("iOSLike", "30.0", IPHONES)]
        self.assertEqual(self.pick(runtimes), ("iOS-27-0", "iPhone-18-Pro"))

    def test_runtime_without_supported_types_key(self):
        bare = runtime("iOS", "28.0", [])
        del bare["supportedDeviceTypes"]
        self.assertEqual(self.pick(UNIVERSAL + [bare]), ("iOS-27-0", "iPhone-18-Pro"))

    def test_nothing_supported_prints_nothing(self):
        self.assertIsNone(self.pick([runtime("iOS", "27.1", ["iPhone Duo"])], IPHONES))
        self.assertIsNone(self.pick([], DEVICE_TYPES))


# The selection apple.yml ran before select-sim-pair.jq, verbatim: newest
# runtime and first matching device type, each chosen on its own.
OLD_RUNTIME = """
  $runtimes[0].runtimes
  | map(select(.isAvailable and (.name | startswith($fam + " "))))
  | sort_by(.version | split(".") | map(tonumber))
  | reverse | .[0].identifier // empty
"""
OLD_DEVICE = """
  $devicetypes[0].devicetypes
  | map(select(.name | startswith($pfx)))
  | .[0].identifier // empty
"""


class OldIndependentPick(unittest.TestCase):
    """Negative control: the fixture reproduces the refused 2026-10-22 pair."""

    def test_old_selection_pairs_an_unsupported_device(self):
        args = ("--arg", "fam", "iOS", "--arg", "pfx", "iPhone")
        [runtime_id] = run_jq(OLD_RUNTIME, XCODE_27_2_IMAGE, DEVICE_TYPES, *args, program_file=False)
        [type_id] = run_jq(OLD_DEVICE, XCODE_27_2_IMAGE, DEVICE_TYPES, *args, program_file=False)
        self.assertEqual((runtime_id, type_id), (RUNTIME + "iOS-27-1", DEVICE + "iPhone-18-Pro"))
        chosen = next(r for r in XCODE_27_2_IMAGE if r["identifier"] == runtime_id)
        self.assertNotIn(type_id, [t["identifier"] for t in chosen["supportedDeviceTypes"]])


if __name__ == "__main__":
    unittest.main()
