#!/usr/bin/env python3
"""End-to-end check of the browser extension's pending-address backend.

The extension creates an address the moment the user commits to it, before the
sign-up form is submitted, so DNS and the mail tiers have time to converge
before any verification message arrives. Such an address is marked
``pending``; it is confirmed by the extension calling ``/confirm_address`` on
form submit, or by mail actually arriving at it (the IMAP tier's procmail
hook), and is revoked by the hourly ``reap_pending_addresses`` Lambda if
neither happens within ``PENDING_TTL_HOURS`` (default 24).

This script exercises every part of that lifecycle it can drive without
sending mail:

  1. create a pending address                     -> 201, row carries the marker
  2. it appears in GET /list flagged pending
  3. POST /confirm_address                        -> 200, marker cleared
  4. POST /confirm_address again                  -> 409 (idempotent by contract)
  5. create a second address, backdate it past the TTL, invoke the reaper
                                                  -> reaped, row gone, absent from /list

Two checks need a live mailbox or a shell in the container and stay manual;
see docs/browser-extension.md.

Addresses it creates are revoked on the way out unless --keep is given.

Credentials
-----------
Sign-in happens against Cognito directly, so the only account you need is a
user in the environment's pool. Steps 1-4 need nothing else. Step 5 and the
DynamoDB assertions additionally need AWS credentials for the environment's
account (DynamoDB read, Lambda invoke); pass --no-aws to skip them.

Usage:

  export CABALMAIL_USERNAME='<cognito user>'
  export CABALMAIL_PASSWORD='...'
  ./scripts/verify-pending-addresses.py --control-domain example.net \\
      --mail-domain example.com --totp 123456

  # or, with a token you already hold
  CABALMAIL_ID_TOKEN='...' ./scripts/verify-pending-addresses.py \\
      --control-domain example.net
"""

import argparse
import json
import os
import secrets
import subprocess
import sys
import urllib.error
import urllib.request

LOG_TAG = "[verify-pending]"
BACKDATED = "2000-01-01T00:00:00+00:00"


def log(message):
    """Print a tagged progress line."""
    print(f"{LOG_TAG} {message}", flush=True)


class CheckFailed(Exception):
    """A verification step did not produce the documented result."""


class Checks:
    """Running tally of verification steps, so one failure does not hide the rest."""

    def __init__(self):
        self.passed = 0
        self.failed = []

    def record(self, name, ok, detail=""):
        """Log one step's outcome and remember failures."""
        if ok:
            self.passed += 1
            log(f"  PASS  {name}")
        else:
            self.failed.append(name)
            log(f"  FAIL  {name}{': ' + detail if detail else ''}")
        return ok


# --------------------------------------------------------------------------
# HTTP / Cognito / API
# --------------------------------------------------------------------------

def http_json(url, method="GET", body=None, headers=None):
    """Issue a JSON request and return (status, parsed-body-or-text)."""
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Content-Type", "application/json")
    for key, value in (headers or {}).items():
        request.add_header(key, value)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            payload = response.read().decode()
            status = response.status
    except urllib.error.HTTPError as err:
        payload = err.read().decode()
        status = err.code
    try:
        return status, json.loads(payload)
    except json.JSONDecodeError:
        return status, payload


def fetch_config(control_domain):
    """Fetch the environment's runtime configuration document."""
    url = f"https://admin.{control_domain}/config.json"
    status, config = http_json(url)
    if status != 200 or not isinstance(config, dict):
        sys.exit(f"{LOG_TAG} error: could not read {url} (status {status})")
    return config


def cognito(region, target, payload):
    """Call an unauthenticated Cognito Identity Provider action."""
    url = f"https://cognito-idp.{region}.amazonaws.com/"
    data = json.dumps(payload).encode()
    request = urllib.request.Request(url, data=data, method="POST")
    request.add_header("Content-Type", "application/x-amz-json-1.1")
    request.add_header("X-Amz-Target", f"AWSCognitoIdentityProviderService.{target}")
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.loads(response.read().decode())
    except urllib.error.HTTPError as err:
        sys.exit(f"{LOG_TAG} error: Cognito {target} failed: {err.read().decode()}")


def id_token(config, username, password, totp):
    """Sign in and return the raw IdToken the API expects in Authorization."""
    region = config["cognitoConfig"]["region"]
    client_id = config["cognitoConfig"]["poolData"]["ClientId"]
    result = cognito(region, "InitiateAuth", {
        "AuthFlow": "USER_PASSWORD_AUTH",
        "ClientId": client_id,
        "AuthParameters": {"USERNAME": username, "PASSWORD": password},
    })
    if result.get("ChallengeName") == "SOFTWARE_TOKEN_MFA":
        if not totp:
            sys.exit(f"{LOG_TAG} error: the user is MFA-enrolled; pass --totp <6 digits>")
        result = cognito(region, "RespondToAuthChallenge", {
            "ClientId": client_id,
            "ChallengeName": "SOFTWARE_TOKEN_MFA",
            "Session": result["Session"],
            "ChallengeResponses": {
                "USERNAME": username,
                "SOFTWARE_TOKEN_MFA_CODE": totp,
            },
        })
    elif result.get("ChallengeName"):
        sys.exit(f"{LOG_TAG} error: unsupported auth challenge "
                 f"{result['ChallengeName']}")
    try:
        return result["AuthenticationResult"]["IdToken"]
    except KeyError:
        sys.exit(f"{LOG_TAG} error: no IdToken in the Cognito response")


class Api:
    """Thin client for the environment's API Gateway surface."""

    def __init__(self, invoke_url, token):
        self.base = invoke_url.rstrip("/")
        self.token = token

    def call(self, method, path, body=None):
        """Issue one authenticated API request."""
        return http_json(f"{self.base}/{path.lstrip('/')}", method=method,
                         body=body, headers={"Authorization": self.token})


# --------------------------------------------------------------------------
# AWS CLI helpers
# --------------------------------------------------------------------------

class Aws:
    """The subset of AWS calls this check needs, shelled out to the CLI."""

    def __init__(self, profile, region, table):
        self.profile = profile
        self.region = region
        self.table = table

    def run(self, *args):
        """Run one aws CLI command and return its parsed JSON output."""
        command = ["aws", *args, "--output", "json"]
        if self.profile:
            command += ["--profile", self.profile]
        if self.region:
            command += ["--region", self.region]
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        if result.returncode != 0:
            raise CheckFailed(result.stderr.strip() or f"aws {' '.join(args)} failed")
        return json.loads(result.stdout) if result.stdout.strip() else {}

    def get_item(self, address):
        """Return the address's DynamoDB row, or None when it is gone."""
        response = self.run("dynamodb", "get-item", "--table-name", self.table,
                            "--key", json.dumps({"address": {"S": address}}))
        return response.get("Item")

    def backdate(self, address):
        """Move an address's pending timestamp past any plausible TTL."""
        self.run("dynamodb", "update-item", "--table-name", self.table,
                 "--key", json.dumps({"address": {"S": address}}),
                 "--update-expression", "SET pending_since = :old",
                 "--expression-attribute-values",
                 json.dumps({":old": {"S": BACKDATED}}))

    def invoke_reaper(self, function_name):
        """Invoke the TTL reaper synchronously and return its parsed body."""
        # The CLI insists on a file for the payload; /dev/stdout keeps it in
        # the pipeline without a temp file.
        result = subprocess.run(
            ["aws", "lambda", "invoke", "--function-name", function_name,
             "--cli-binary-format", "raw-in-base64-out", "--payload", "{}",
             "/dev/stdout"]
            + (["--profile", self.profile] if self.profile else [])
            + (["--region", self.region] if self.region else []),
            capture_output=True, text=True, check=False)
        if result.returncode != 0:
            raise CheckFailed(result.stderr.strip() or "lambda invoke failed")
        # stdout carries the function response followed by the CLI's own JSON
        # summary; the first line is the response.
        first = result.stdout.strip().splitlines()[0]
        response = json.loads(first)
        return json.loads(response.get("body", "{}"))


# --------------------------------------------------------------------------
# The verification itself
# --------------------------------------------------------------------------

def random_label():
    """An 8-character label that satisfies the local-part and DNS-label rules."""
    return secrets.token_hex(4)


def listed_addresses(body):
    """The address entries from a GET /list response body."""
    return body.get("Items", []) if isinstance(body, dict) else []


def create_pending(api, mail_domain, checks):
    """Create one pending address and return it, or None if creation failed."""
    local, subdomain = random_label(), random_label()
    address = f"{local}@{subdomain}.{mail_domain}"
    status, body = api.call("POST", "/new", {
        "username": local,
        "subdomain": subdomain,
        "tld": mail_domain,
        "comment": "verify-pending-addresses",
        "address": address,
        "pending": True,
    })
    ok = checks.record(f"POST /new creates {address}", status == 201,
                       f"status {status}: {body}")
    return address if ok else None


def verify_lifecycle(api, aws, mail_domain, checks, created):
    """Steps 1-4: create, list, confirm, confirm again."""
    log("create a pending address")
    address = create_pending(api, mail_domain, checks)
    if not address:
        return
    created.append(address)

    if aws:
        item = aws.get_item(address)
        checks.record("DynamoDB row is marked pending",
                      bool(item) and item.get("pending", {}).get("BOOL") is True,
                      f"row: {item}")
        checks.record("DynamoDB row carries pending_since",
                      bool(item) and "pending_since" in item)

    status, body = api.call("GET", "/list")
    listed = [a for a in listed_addresses(body) if a.get("address") == address]
    checks.record("GET /list shows the address as pending",
                  bool(listed) and listed[0].get("pending") is True,
                  f"status {status}, entry {listed}")

    log("confirm it")
    status, body = api.call("POST", "/confirm_address", {"address": address})
    checks.record("POST /confirm_address returns 200", status == 200,
                  f"status {status}: {body}")

    if aws:
        item = aws.get_item(address)
        checks.record("pending marker is cleared",
                      bool(item) and "pending" not in item, f"row: {item}")

    status, body = api.call("POST", "/confirm_address", {"address": address})
    checks.record("confirming twice returns 409", status == 409,
                  f"status {status}: {body}")


def verify_reaper(api, aws, mail_domain, checks, created, function_name):
    """Step 5: a pending address older than the TTL is revoked by the reaper."""
    log("reap an expired pending address")
    address = create_pending(api, mail_domain, checks)
    if not address:
        return
    created.append(address)

    aws.backdate(address)
    result = aws.invoke_reaper(function_name)
    checks.record("reaper reports at least one reaped address",
                  result.get("reaped", 0) >= 1, f"result: {result}")
    checks.record("DynamoDB row is gone", aws.get_item(address) is None)

    status, body = api.call("GET", "/list")
    still_listed = any(a.get("address") == address for a in listed_addresses(body))
    checks.record("address is absent from GET /list", not still_listed,
                  f"status {status}")
    if not still_listed:
        created.remove(address)


def cleanup(api, created):
    """Revoke every address this run created and left behind."""
    for address in list(created):
        status, body = api.call("DELETE", "/revoke", {"address": address})
        if status in (200, 202):
            log(f"revoked {address}")
        else:
            log(f"warning: could not revoke {address} (status {status}: {body})")


def main():
    """Parse arguments, run the checks, and report."""
    parser = argparse.ArgumentParser(
        description="Verify the pending-address lifecycle in a live environment.")
    parser.add_argument("--control-domain", required=True,
                        help="the environment's control domain")
    parser.add_argument("--mail-domain",
                        help="mail domain to create test addresses on "
                             "(default: the first one config.json advertises)")
    parser.add_argument("--username", default=os.environ.get("CABALMAIL_USERNAME"),
                        help="Cognito username (env CABALMAIL_USERNAME)")
    parser.add_argument("--password", default=os.environ.get("CABALMAIL_PASSWORD"),
                        help="Cognito password (env CABALMAIL_PASSWORD)")
    parser.add_argument("--totp", help="current TOTP code, if the user is MFA-enrolled")
    parser.add_argument("--id-token", default=os.environ.get("CABALMAIL_ID_TOKEN"),
                        help="skip sign-in and use this IdToken (env CABALMAIL_ID_TOKEN)")
    parser.add_argument("--profile", help="AWS profile for the environment's account")
    parser.add_argument("--region", help="AWS region (default: the pool's region)")
    parser.add_argument("--table", default="cabal-addresses",
                        help="DynamoDB address table (default: cabal-addresses)")
    parser.add_argument("--reaper-function", default="reap_pending_addresses",
                        help="TTL reaper Lambda (default: reap_pending_addresses)")
    parser.add_argument("--no-aws", action="store_true",
                        help="run only the checks that need no AWS credentials")
    parser.add_argument("--keep", action="store_true",
                        help="leave the addresses this run created in place")
    args = parser.parse_args()

    config = fetch_config(args.control_domain)
    mail_domain = args.mail_domain or next(
        (d["domain"] for d in config.get("domains", []) if d.get("domain")), None)
    if not mail_domain:
        sys.exit(f"{LOG_TAG} error: no mail domain given and none in config.json")

    token = args.id_token
    if not token:
        if not (args.username and args.password):
            sys.exit(f"{LOG_TAG} error: give --id-token, or --username and --password")
        token = id_token(config, args.username, args.password, args.totp)

    api = Api(config["invokeUrl"], token)
    aws = None if args.no_aws else Aws(
        args.profile, args.region or config["cognitoConfig"]["region"], args.table)

    log(f"environment: {args.control_domain} (mail domain {mail_domain})")
    if not aws:
        log("AWS checks disabled: skipping the DynamoDB assertions and the reaper")

    checks = Checks()
    created = []
    try:
        verify_lifecycle(api, aws, mail_domain, checks, created)
        if aws:
            verify_reaper(api, aws, mail_domain, checks, created, args.reaper_function)
    except CheckFailed as err:
        checks.record("AWS call", False, str(err))
    finally:
        if args.keep:
            log(f"leaving {len(created)} address(es) in place: {', '.join(created)}")
        else:
            cleanup(api, created)

    log(f"{checks.passed} passed, {len(checks.failed)} failed")
    if checks.failed:
        log("failures: " + ", ".join(checks.failed))
        return 1
    log("still to check by hand: the procmail rule regenerates on the IMAP tier, "
        "and mail arriving at a pending address clears it. "
        "See docs/browser-extension.md.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
