#!/usr/bin/env python3
"""Mint, list and revoke agent access grants for the read-only /mcp endpoint.

An agent (an MCP client such as Claude Code) reaches a mailbox through
``POST /mcp`` with a bearer token. Tokens are minted by the mailbox owner
through the Cognito-authenticated ``/new_agent_grant`` endpoint; this script
signs in the same way the webmail does and calls it, so no AWS credentials are
needed. See docs/agent-access.md.

Phase A grants are read-only and cover INBOX only. The token is shown once,
at mint time; the service keeps only its hash, so a lost token is revoked and
re-minted, never recovered.

Usage:

  export CABALMAIL_USERNAME='<cognito user>'
  export CABALMAIL_PASSWORD='...'
  ./scripts/agent-grant.py --control-domain example.net --totp 123456 \\
      mint --label "Claude Code on my laptop" --days 30
  ./scripts/agent-grant.py --control-domain example.net --totp 123456 list
  ./scripts/agent-grant.py --control-domain example.net --totp 123456 \\
      revoke 0123456789abcdef

  # or, with an ID token you already hold
  CABALMAIL_ID_TOKEN='...' ./scripts/agent-grant.py --control-domain example.net list
"""

import argparse
import datetime
import json
import os
import shlex
import sys
import urllib.error
import urllib.request

LOG_TAG = "[agent-grant]"


def fail(message):
    """Exit with a tagged error."""
    sys.exit(f"{LOG_TAG} error: {message}")


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
        fail(f"could not read {url} (status {status})")
    return config


def cognito(region, target, payload):
    """Call an unauthenticated Cognito Identity Provider action."""
    url = f"https://cognito-idp.{region}.amazonaws.com/"
    request = urllib.request.Request(url, data=json.dumps(payload).encode(), method="POST")
    request.add_header("Content-Type", "application/x-amz-json-1.1")
    request.add_header("X-Amz-Target", f"AWSCognitoIdentityProviderService.{target}")
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.loads(response.read().decode())
    except urllib.error.HTTPError as err:
        return fail(f"Cognito {target} failed: {err.read().decode()}")


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
            fail("the user is MFA-enrolled; pass --totp <6 digits>")
        result = cognito(region, "RespondToAuthChallenge", {
            "ClientId": client_id,
            "ChallengeName": "SOFTWARE_TOKEN_MFA",
            "Session": result["Session"],
            "ChallengeResponses": {"USERNAME": username, "SOFTWARE_TOKEN_MFA_CODE": totp},
        })
    elif result.get("ChallengeName"):
        fail(f"unsupported auth challenge {result['ChallengeName']}")
    try:
        return result["AuthenticationResult"]["IdToken"]
    except KeyError:
        return fail("no IdToken in the Cognito response")


def when(epoch):
    """Render an epoch-seconds field for the listing."""
    if not epoch:
        return "-"
    moment = datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc)
    return moment.strftime("%Y-%m-%d %H:%M UTC")


def describe(grant):
    """One line per grant for the listing."""
    state = "live" if grant.get("live") else ("revoked" if grant.get("revoked") else "expired")
    return (f"{grant['grant_id']}  {state:<7}  {grant.get('access')}  "
            f"{','.join(grant.get('folders') or [])}  expires {when(grant.get('expires_at'))}  "
            f"last used {when(grant.get('last_used_at'))}  {grant.get('label') or ''}")


def parse_args(argv):
    """Command-line surface."""
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--control-domain", required=True,
                        help="the environment's control domain (config.json lives on admin.<it>)")
    parser.add_argument("--totp", help="current TOTP code, if the user is MFA-enrolled")
    sub = parser.add_subparsers(dest="command", required=True)
    mint = sub.add_parser("mint", help="mint a read-only INBOX grant; prints its token once")
    mint.add_argument("--label", required=True, help="what the token is for")
    mint.add_argument("--days", type=int, default=90, help="lifetime in days (1-365, default 90)")
    sub.add_parser("list", help="list your grants, newest first")
    revoke = sub.add_parser("revoke", help="revoke a grant by its id")
    revoke.add_argument("grant_id")
    return parser.parse_args(argv)


def main(argv=None):
    """Sign in, then mint, list or revoke."""
    args = parse_args(argv)
    config = fetch_config(args.control_domain)
    token = os.environ.get("CABALMAIL_ID_TOKEN")
    if not token:
        username = os.environ.get("CABALMAIL_USERNAME")
        password = os.environ.get("CABALMAIL_PASSWORD")
        if not username or not password:
            fail("set CABALMAIL_USERNAME and CABALMAIL_PASSWORD, or CABALMAIL_ID_TOKEN")
        token = id_token(config, username, password, args.totp)
    base = config["invokeUrl"].rstrip("/")
    headers = {"Authorization": token}

    if args.command == "mint":
        status, body = http_json(f"{base}/new_agent_grant", "POST",
                                 {"label": args.label, "expires_in_days": args.days}, headers)
        if status != 201:
            fail(f"mint failed ({status}): {body}")
        print(f"{LOG_TAG} minted grant {body['grant_id']} "
              f"(read-only, INBOX, expires {when(body['expires_at'])})", file=sys.stderr)
        print(f"{LOG_TAG} the token below is shown once; store it now.", file=sys.stderr)
        print(body["token"])
        mcp_url = body.get("mcp_url") or f"{base}/mcp"
        add = ["claude", "mcp", "add", "--transport", "http", "cabalmail", mcp_url,
               "--header", f"Authorization: Bearer {body['token']}"]
        print(f"{LOG_TAG} to add it to Claude Code:\n  {shlex.join(add)}", file=sys.stderr)
    elif args.command == "list":
        status, body = http_json(f"{base}/list_agent_grants", "GET", None, headers)
        if status != 200:
            fail(f"list failed ({status}): {body}")
        grants = body.get("grants") or []
        if not grants:
            print(f"{LOG_TAG} no grants", file=sys.stderr)
        for grant in grants:
            print(describe(grant))
    else:
        status, body = http_json(f"{base}/revoke_agent_grant", "POST",
                                 {"grant_id": args.grant_id}, headers)
        if status != 200:
            fail(f"revoke failed ({status}): {body}")
        print(f"{LOG_TAG} revoked {args.grant_id}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
