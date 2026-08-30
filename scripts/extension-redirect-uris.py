#!/usr/bin/env python3
"""Compute the browser extension's Chrome OAuth redirect URIs and stage them for Terraform.

The extension signs in through the Cognito Hosted UI with PKCE. On Chrome the
interactive leg runs through ``identity.launchWebAuthFlow``, whose redirect URL
is derived from the extension ID, so the user pool's extension app client must
whitelist one URL per shipped Chrome build:

  * The unpacked (development) build's ID is pinned by the ``key`` field in
    ``extensions/chrome/manifest.template.json`` -- it is the same on every
    machine and can be computed offline, which is what this script does.
  * The Chrome Web Store build's ID is assigned by the store at first upload
    and is *different*, because the store build strips the ``key``. Read it
    off the listing and pass it with ``--store-id``.

Safari needs nothing here. It implements no WebExtensions ``identity`` API, so
its sign-in runs the Hosted UI in an ordinary tab redirecting to
``https://admin.<control-domain>/extension-auth``, which Terraform registers on
the app client unconditionally.

Terraform reads the Chrome list from the ``extension_redirect_uris`` variable,
fed by the GitHub environment variable ``TF_VAR_EXTENSION_REDIRECT_URIS``. That
value is expanded inside a double-quoted shell ``echo`` in ``infra.yml``, so
every quote in the stored value must be backslash-escaped or the shell eats it
and Terraform receives unparseable HCL. This script emits the escaped form, and
with ``--set`` writes it to the environment for you.

Usage:

  # Just show the development build's redirect URI
  ./scripts/extension-redirect-uris.py

  # Both URIs, ready to paste into the GitHub environment variable
  ./scripts/extension-redirect-uris.py --store-id <chrome-store-id>

  # ...and set it on an environment (needs the gh CLI, authenticated)
  ./scripts/extension-redirect-uris.py --store-id <id> --set --env stage
"""

import argparse
import base64
import hashlib
import json
import pathlib
import subprocess
import sys

LOG_TAG = "[extension-redirect-uris]"
REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
MANIFEST = REPO_ROOT / "extensions" / "chrome" / "manifest.template.json"


def chrome_id_from_key(key_b64):
    """Derive a Chrome extension ID from the base64 SubjectPublicKeyInfo in a manifest key.

    Chrome takes the SHA-256 of the DER-encoded public key, keeps the first 16
    bytes (32 hex digits), and maps each hex digit 0-f onto a-p.
    """
    digest = hashlib.sha256(base64.b64decode(key_b64)).hexdigest()[:32]
    return "".join(chr(ord("a") + int(c, 16)) for c in digest)


def dev_extension_id():
    """The unpacked build's extension ID, read from the committed manifest key."""
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    key = manifest.get("key")
    if not key:
        sys.exit(
            f"{LOG_TAG} error: {MANIFEST} has no 'key' field, so the unpacked "
            "extension ID is not stable. Add one (see docs/browser-extension.md)."
        )
    return chrome_id_from_key(key)


def escaped_hcl_list(uris):
    """The TF_VAR value as infra.yml needs it stored: an HCL list with escaped quotes."""
    return "[" + ", ".join('\\"' + u + '\\"' for u in uris) + "]"


def main():
    parser = argparse.ArgumentParser(
        description="Compute the extension's Chrome OAuth redirect URIs.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--store-id",
        action="append",
        default=[],
        metavar="ID",
        help="a store-assigned Chrome extension ID (repeatable)",
    )
    parser.add_argument(
        "--uri",
        action="append",
        default=[],
        metavar="URI",
        help="an extra redirect URI to include verbatim (repeatable)",
    )
    parser.add_argument(
        "--no-dev",
        action="store_true",
        help="omit the unpacked development build's URI (store builds only)",
    )
    parser.add_argument(
        "--set",
        action="store_true",
        help="write the value to TF_VAR_EXTENSION_REDIRECT_URIS with the gh CLI",
    )
    parser.add_argument(
        "--env",
        metavar="ENVIRONMENT",
        help="GitHub environment to set the variable on (required with --set)",
    )
    args = parser.parse_args()

    ids = [] if args.no_dev else [dev_extension_id()]
    ids += args.store_id
    uris = [f"https://{i}.chromiumapp.org/" for i in ids] + args.uri
    if not uris:
        sys.exit(f"{LOG_TAG} error: no redirect URIs to emit")

    for uri in uris:
        print(uri)

    value = escaped_hcl_list(uris)
    print(f"\n{LOG_TAG} TF_VAR_EXTENSION_REDIRECT_URIS={value}", file=sys.stderr)

    if not args.set:
        return
    if not args.env:
        sys.exit(f"{LOG_TAG} error: --set requires --env")
    subprocess.run(
        ["gh", "variable", "set", "TF_VAR_EXTENSION_REDIRECT_URIS",
         "--env", args.env, "--body", value],
        check=True,
    )
    print(f"{LOG_TAG} set on environment {args.env}", file=sys.stderr)


if __name__ == "__main__":
    main()
