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
#   ASC_POLL_TIMEOUT  Seconds to wait overall (default 1200)
#   ASC_POLL_INTERVAL Seconds between attempts (default 30)

import os
import sys
import time
import urllib.error
import urllib.parse

from asc_api import (
    api_request,
    error,
    find_app_id,
    find_build,
    make_token,
    notice,
    require_env,
)


def find_group_id(app_id, group_name, token_factory):
    """Return the betaGroups id for `group_name` within `app_id`, or None."""
    query = urllib.parse.urlencode(
        {"filter[app]": app_id, "filter[name]": group_name, "limit": 5}
    )
    result = api_request("GET", f"/v1/betaGroups?{query}", token_factory)
    for group in result.get("data") or []:
        # filter[name] is documented as exact-match; verify anyway so a
        # surprise substring match can't route builds to the wrong group.
        if group.get("attributes", {}).get("name") == group_name:
            return group["id"]
    return None


def attach(group_id, build_id, token_factory):
    """Add `build_id` to `group_id`; raises urllib.error.HTTPError on refusal.

    Adding a build that is already in the group is a no-op success, so
    retrying after a lost response is safe.
    """
    api_request(
        "POST",
        f"/v1/betaGroups/{group_id}/relationships/builds",
        token_factory,
        body={"data": [{"type": "builds", "id": build_id}]},
    )


def main():
    key_id = require_env("ASC_KEY_ID")
    issuer_id = require_env("ASC_ISSUER_ID")
    key_path = require_env("ASC_KEY_PATH")
    bundle_id = require_env("BUNDLE_ID")
    build_number = require_env("BUILD_NUMBER")
    group_name = require_env("TF_GROUP")
    timeout = int(os.environ.get("ASC_POLL_TIMEOUT", "1200"))
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
    print(f"Attaching build {build_number} of {bundle_id} to group {group_name!r}...")

    deadline = time.time() + timeout
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
            if state == "VALID":
                # Fully processed and still refused: terminal.
                error(
                    f"Could not attach build {build_number} to {group_name!r}: "
                    f"HTTP {err.code} {detail or err.reason}"
                )
                return 1
            print(
                f"Attach refused while processingState={state} "
                f"(HTTP {err.code}); retrying in {interval}s."
            )
            time.sleep(interval)
            continue
        notice(
            f"Attached build {build_number} to group {group_name!r} "
            f"(processingState {state})."
        )
        return 0
    error(
        f"Build {build_number} was not attached to {group_name!r} within "
        f"{timeout}s. Attach it manually: App Store Connect -> TestFlight -> "
        f"{group_name} -> Builds -> +."
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
