#!/usr/bin/env python3
#
# Attach a freshly-uploaded build to a TestFlight internal test group.
#
# apple.yml's upload jobs run this right after `altool --upload-app`.
# Distribution used to rely on App Store Connect's "automatic distribution"
# group setting, which fires exactly once per build (when processing
# finishes) and never retries: a misfire leaves the build fully processed
# but attached to no group — invisible to testers and to CI, which had
# already gone green at upload time. A run of consecutive macOS builds
# once vanished exactly that way. This script makes distribution
# deterministic and branch-aware instead: each build is attached to the
# internal group named by TF_GROUP (stage pushes -> "stage", main ->
# "prod"), and a build that cannot be attached fails the step loudly
# rather than silently never reaching testers. Automatic distribution
# should be switched OFF on the groups once this is in place — leaving it
# on re-adds every build to every group and the branch routing means
# nothing (see docs/apple.md).
#
# Attachment is attempted as soon as the build resource surfaces in the
# API, which is usually minutes before processing completes. If App Store
# Connect refuses while the build is still processing, the script keeps
# polling and retrying until the build turns VALID (at which point a
# refusal is terminal) or the timeout lapses.
#
# Required env:
#   ASC_KEY_ID        App Store Connect API key id (the AuthKey_<id>.p8 id)
#   ASC_ISSUER_ID     App Store Connect API issuer id
#   ASC_KEY_PATH      Path to the decoded .p8 private key
#   BUNDLE_ID         App bundle id (e.g. com.cabalmail.Cabalmail)
#   BUILD_NUMBER      CFBundleVersion of the uploaded build
#   TF_GROUP          Name of the internal test group to attach to
# Optional env:
#   ASC_POLL_TIMEOUT  Seconds to wait overall (default 2400 - Apple-side
#                     ingestion of a fresh upload has been observed to
#                     exceed 20 minutes, so the ceiling errs high; the
#                     usual attach lands in the first few minutes)
#   ASC_POLL_INTERVAL Seconds between attempts (default 30)

import os
import sys
import time
import urllib.error

from asc_api import (
    api_request,
    error,
    find_app_id,
    find_build,
    make_token,
    notice,
    require_env,
    warn,
)

# A known App Store Connect defect (observed since 2026-07-17, Apple
# support case pending): builds can take 10+ hours - previously minutes -
# to reach the hidden "Ready to Test" state that gates ALL distribution.
# Until a build ripens, no attach path exists anywhere: the ASC web UI's
# "Test a Build" dialog lists the build but cannot select it, and the API
# either 404s the build id on both relationship directions ("no resource
# of type 'builds'", even though GET /v1/builds reports it VALID - the
# usual macOS shape) or doesn't surface the build in /v1/builds at all
# (seen on iOS). The delay varies per build; macOS has been consistently
# at the long end. When the 404-on-VALID signature repeats this many
# times, the step downgrades to a warning instead of burning the full
# poll window and failing a release CI can do nothing about - and a poll
# that times out with the build never surfacing gets the same downgrade,
# since altool has already verified the upload by then. Genuine failures
# (FAILED/INVALID processing, missing group, any other persistent
# refusal) still fail loudly, and for builds that ripen in time the
# attach simply succeeds and none of this engages.
KNOWN_DEFECT_ATTEMPTS = 10


def find_group_id(app_id, group_name, token_factory):
    """Return the id of the app's own test group `group_name`, or None.

    Looks up through the app's betaGroups relationship URL and matches the
    name client-side, rather than /v1/betaGroups?filter[app]=&filter[name]=.
    Group names are only unique per app — every app record carries a
    `stage` and a `prod` — and a top-level filter that silently drops one
    constraint (an ASC habit) can hand back another app's group. Attaching
    a build to a group on the wrong app fails with a misleading NOT_FOUND
    on the *build* ("no resource of type 'builds'"), because the
    relationship validator scopes build lookup to the group's app. Scoping
    the lookup URL to the app makes that structurally impossible.
    """
    result = api_request(
        "GET", f"/v1/apps/{app_id}/betaGroups?limit=200", token_factory
    )
    for group in result.get("data") or []:
        if group.get("attributes", {}).get("name") == group_name:
            return group["id"]
    return None


def attach(group_id, build_id, token_factory):
    """Add `build_id` to `group_id`; raises urllib.error.HTTPError on refusal.

    Uses the build -> betaGroups relationship direction. The reverse
    (POST /v1/betaGroups/{id}/relationships/builds) 404s macOS build ids
    ("no resource of type 'builds'") even after /v1/builds reports the
    same build as VALID; this direction is the one fastlane exercises and
    works for every platform. Adding a build to a group it is already in
    is a no-op success, so retrying after a lost response is safe.
    """
    api_request(
        "POST",
        f"/v1/builds/{build_id}/relationships/betaGroups",
        token_factory,
        body={"data": [{"type": "betaGroups", "id": group_id}]},
    )


def main():
    key_id = require_env("ASC_KEY_ID")
    issuer_id = require_env("ASC_ISSUER_ID")
    key_path = require_env("ASC_KEY_PATH")
    bundle_id = require_env("BUNDLE_ID")
    build_number = require_env("BUILD_NUMBER")
    group_name = require_env("TF_GROUP")
    timeout = int(os.environ.get("ASC_POLL_TIMEOUT", "2400"))
    interval = int(os.environ.get("ASC_POLL_INTERVAL", "30"))

    with open(key_path, encoding="utf-8") as handle:
        private_key = handle.read()

    def token_factory():
        return make_token(key_id, issuer_id, private_key)

    app_id = find_app_id(bundle_id, token_factory)
    if app_id is None:
        error(f"No App Store Connect app found for bundle id {bundle_id}.")
        return 1
    group_id = find_group_id(app_id, group_name, token_factory)
    if group_id is None:
        error(
            f"No test group named {group_name!r} on app {bundle_id}. Create it "
            "in App Store Connect -> TestFlight -> Internal Testing, or attach "
            f"build {build_number} by hand."
        )
        return 1
    print(f"Resolved app {bundle_id} -> {app_id}, group {group_name!r} -> {group_id}")
    print(f"Attaching build {build_number} of {bundle_id} to group {group_name!r}...")

    deadline = time.time() + timeout
    last_refusal = ""
    defect_hits = 0
    while time.time() < deadline:
        build = find_build(app_id, build_number, token_factory)
        if build is None:
            # Upload accepted but the build resource hasn't surfaced yet.
            time.sleep(interval)
            continue
        state = build.get("attributes", {}).get("processingState")
        if state in ("FAILED", "INVALID"):
            error(f"Build {build_number} processing state is {state}; cannot attach.")
            return 1
        try:
            attach(group_id, build["id"], token_factory)
        except urllib.error.HTTPError as err:
            detail = ""
            try:
                detail = err.read().decode()
            except Exception:  # pylint: disable=broad-except
                pass
            # ASC refuses attachment while the build is still processing,
            # and is eventually consistent even afterwards. No refusal is
            # terminal on its own; retry until the deadline - except the
            # known-defect signature, which caps out early (see
            # KNOWN_DEFECT_ATTEMPTS above).
            last_refusal = f"HTTP {err.code} {detail or err.reason}"
            if err.code == 404 and state == "VALID" and "type 'builds'" in detail:
                defect_hits += 1
                if defect_hits >= KNOWN_DEFECT_ATTEMPTS:
                    warn(
                        f"Build {build_number} is VALID but App Store Connect "
                        f"404s it on every group-attach path ({defect_hits} "
                        "attempts) - the known delayed-readiness defect. Not "
                        f"failing the job; attach to {group_name!r} manually "
                        'once the build reaches "Ready to Test" (hours, '
                        "currently), or let the next push supersede it."
                    )
                    return 0
            else:
                defect_hits = 0
            print(
                f"Attach refused (processingState={state}): {last_refusal}; "
                f"retrying in {interval}s."
            )
            time.sleep(interval)
            continue
        notice(
            f"Attached build {build_number} to group {group_name!r} "
            f"(processingState {state})."
        )
        return 0
    if last_refusal:
        error(
            f"Build {build_number} was not attached to {group_name!r} within "
            f"{timeout}s. Last refusal: {last_refusal}. Attach it manually: "
            f"App Store Connect -> TestFlight -> {group_name} -> Builds -> +."
        )
        return 1
    # Never surfaced in /v1/builds at all. altool verified the upload
    # before this step ran, so this is the delayed-readiness defect
    # manifesting one API layer earlier (the iOS shape) - same downgrade.
    warn(
        f"Build {build_number} has not surfaced in the App Store Connect API "
        f"after {timeout}s despite a verified upload - the known "
        "delayed-readiness defect. Not failing the job; attach to "
        f"{group_name!r} manually once it reaches \"Ready to Test\", or let "
        "the next push supersede it."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
