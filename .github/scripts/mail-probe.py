#!/usr/bin/env python3
"""
Post-deploy mail probe: prove that mail flows end to end through a freshly
rolled environment, driven entirely from the outside.

Two legs, both run from wherever this script executes (a GitHub-hosted
runner in CI, or an operator's shell):

  api  Sign in to Cognito as the probe user and PUT /send, exactly as the
       clients do. The message travels send Lambda -> smtp-out (submission
       auth, DKIM signing) -> mailertable -> imap (local delivery). The leg
       passes when the message is in the probe user's INBOX carrying a
       DKIM-Signature header.

  mx   Resolve the MX for the probe address and speak plain SMTP to it on
       port 25, the way any internet MTA delivers to us. The message travels
       NLB:25 -> smtp-in (milters, relay) -> imap. The leg passes when the
       message is in INBOX carrying the Authentication-Results header the
       smtp-in milters stamp. This is the only leg that touches smtp-in:
       smtp-out routes hosted domains straight to imap, so an api-only probe
       is blind to a broken smtp-in roll.

Reception is checked through the API (/list_messages, /list_envelopes,
/fetch_message), which also exercises the Lambda-side master-user IMAP
login. On success both messages, and the Sent copy /send queues, are moved
to Trash and purged so the probe mailbox stays empty; on failure they are
left in place for diagnosis and the next run's pre-sweep removes them.

Configuration comes from the environment's public config.json
(https://admin.<control-domain>/config.json) and the probe user's own
address list, so the inputs are the control domain and the password:

  --control-domain      required
  MAIL_PROBE_PASSWORD   environment variable, or
  --password-param      SSM SecureString read via `aws ssm get-parameter`
                        (default /cabal/ci-probe/password)

For an ad-hoc run as a TOTP-enrolled user, --totp-secret-param (or
MAIL_PROBE_TOTP_SECRET) supplies the base32 secret and the script answers
the SOFTWARE_TOKEN_MFA challenge itself. The sweep only ever touches
messages whose subject starts with "[ci-probe]", so running it against a
shared account is safe.

The ci-probe user, its address and its SSM password are provisioned by
terraform/infra/modules/app/ci_probe_user.tf. Invoked from the mail-probe
job in .github/workflows/app.yml. See docs/mail-probe.md.

Exit codes: 0 every requested leg verified; 1 a leg failed or timed out;
2 bad usage or configuration.
"""

import argparse
import base64
import hashlib
import hmac
import json
import os
import smtplib
import ssl
import struct
import subprocess
import sys
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timezone
from email.message import EmailMessage
from email.parser import BytesHeaderParser
from email.utils import format_datetime, make_msgid

LOG_TAG = "[mail-probe]"
SUBJECT_PREFIX = "[ci-probe]"
PROBE_HEADER = "X-Cabal-Test-Probe"
LEGS = ("api", "mx")
DEFAULT_USERNAME = "ci-probe"
DEFAULT_PASSWORD_PARAM = "/cabal/ci-probe/password"
HTTP_TIMEOUT = 30
SMTP_TIMEOUT = 90
POLL_INTERVAL = 10
LIST_WINDOW = 50        # newest messages per folder the probe inspects
SWEEP_WINDOW = 100      # newest messages per folder the sweep inspects
SENT_COPY_GRACE = 30    # seconds to wait for /send's queued Sent copy before cleanup
RETRYABLE_STATUSES = {502, 503, 504}
BODY_TEXT = ("Automated post-deploy probe message from Cabalmail CI.\n"
             "It is deleted by the probe once verified; safe to delete by hand.\n")
BODY_HTML = ("<p>Automated post-deploy probe message from Cabalmail CI.</p>"
             "<p>It is deleted by the probe once verified; safe to delete by hand.</p>")


class ProbeError(Exception):
    """A failed assertion or an unrecoverable configuration problem."""


class Retryable(Exception):
    """A transient API failure: maintenance 503, gateway 502/504, or a socket error."""


def log(message):
    print(f"{LOG_TAG} {message}", flush=True)


def annotate(level, message):
    """GitHub Actions workflow command; prints harmlessly outside Actions."""
    print(f"::{level}::{message}", flush=True)


# -- pure helpers (unit-tested in scripts/tests/test_mail_probe.py) ----------

def totp_code(secret_b32, now=None, step=30, digits=6):
    """RFC 6238 code for a base32 secret (HMAC-SHA1, Cognito's algorithm)."""
    normalized = secret_b32.strip().replace(" ", "").upper()
    key = base64.b32decode(normalized + "=" * (-len(normalized) % 8))
    counter = int((time.time() if now is None else now) // step)
    mac = hmac.new(key, struct.pack(">Q", counter), hashlib.sha1).digest()
    offset = mac[-1] & 0x0F
    code = struct.unpack(">I", mac[offset:offset + 4])[0] & 0x7FFFFFFF
    return f"{code % (10 ** digits):0{digits}d}"


def parse_mx(dig_output):
    """Hostnames from `dig +short MX` output, lowest preference first."""
    found = []
    for line in dig_output.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0].isdigit():
            found.append((int(parts[0]), parts[1].rstrip(".").lower()))
    return [host for _, host in sorted(found)]


def probe_uids(envelopes, subjects=None):
    """{uid: subject} for envelopes whose subject is in `subjects`, or - when
    `subjects` is None - for every message that carries the probe prefix."""
    matched = {}
    for uid, envelope in envelopes.items():
        subject = envelope.get("subject") or ""
        if subjects is None:
            if subject.startswith(SUBJECT_PREFIX):
                matched[uid] = subject
        elif subject in subjects:
            matched[uid] = subject
    return matched


def choose_address(items, wanted=None):
    """The probe address: `wanted` if it is one of the user's active addresses,
    otherwise the user's first active address."""
    active = [item["address"] for item in items
              if item.get("address") and not item.get("suspended") and not item.get("pending")]
    if wanted:
        if wanted not in active:
            raise ProbeError(f"{wanted} is not an active address of the probe user")
        return wanted
    if not active:
        raise ProbeError("the probe user has no active address to send to")
    return active[0]


def dkim_domain(headers):
    """The d= tag of the first DKIM-Signature header, '?' if the header has
    no d= tag, None if there is no DKIM-Signature at all."""
    signature = headers.get("DKIM-Signature")
    if signature is None:
        return None
    for tag in str(signature).replace("\r", "").replace("\n", "").split(";"):
        key, _, value = tag.strip().partition("=")
        if key.strip() == "d":
            return value.strip()
    return "?"


def squash(value, limit=160):
    """One line, whitespace collapsed, truncated for logs and summaries."""
    text = " ".join(str(value).split())
    return text if len(text) <= limit else text[:limit - 3] + "..."


# -- credentials and configuration -------------------------------------------

def secret_from(env_name, param_name):
    """A secret from the environment, else from an SSM SecureString. Never logged."""
    value = os.environ.get(env_name)
    if value:
        return value
    if not param_name:
        return None
    try:
        result = subprocess.run(
            ["aws", "ssm", "get-parameter", "--name", param_name, "--with-decryption",
             "--query", "Parameter.Value", "--output", "text"],
            capture_output=True, text=True, check=True, timeout=60)
    except FileNotFoundError:
        raise ProbeError(f"aws CLI not found; set {env_name} instead") from None
    except subprocess.TimeoutExpired:
        raise ProbeError(f"timed out reading SSM parameter {param_name}") from None
    except subprocess.CalledProcessError as err:
        raise ProbeError(
            f"could not read SSM parameter {param_name}: {squash(err.stderr)}") from None
    value = result.stdout.strip()
    if not value:
        raise ProbeError(f"SSM parameter {param_name} is empty")
    return value


def load_config(control_domain):
    """The pieces of the environment's public config.json the probe needs."""
    url = f"https://admin.{control_domain}/config.json"
    try:
        with urllib.request.urlopen(url, timeout=HTTP_TIMEOUT) as resp:
            config = json.load(resp)
    except (urllib.error.URLError, OSError, ValueError) as err:
        raise ProbeError(f"could not load {url}: {err}") from None
    try:
        cognito = config["cognitoConfig"]
        return {
            "invoke_url": config["invokeUrl"],
            "control_domain": config["control_domain"],
            "region": cognito["region"],
            "client_id": cognito["poolData"]["ClientId"],
        }
    except KeyError as err:
        raise ProbeError(f"{url} is missing {err}") from None


def error_detail(err):
    """Best-effort message from an HTTPError body, safe to log."""
    try:
        body = err.read().decode("utf-8", "replace")
    except OSError:
        return ""
    try:
        parsed = json.loads(body)
        for key in ("message", "status", "__type"):
            if isinstance(parsed, dict) and parsed.get(key):
                return squash(parsed[key])
    except ValueError:
        pass
    return squash(body)


class Cognito:
    """Just enough of the Cognito IdP JSON API for a password login."""

    def __init__(self, region, client_id):
        self.endpoint = f"https://cognito-idp.{region}.amazonaws.com/"
        self.client_id = client_id

    def _call(self, target, payload):
        request = urllib.request.Request(
            self.endpoint, data=json.dumps(payload).encode(), method="POST",
            headers={"Content-Type": "application/x-amz-json-1.1",
                     "X-Amz-Target": f"AWSCognitoIdentityProviderService.{target}"})
        try:
            with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT) as resp:
                return json.load(resp)
        except urllib.error.HTTPError as err:
            raise ProbeError(f"Cognito {target} failed: {err.code} {error_detail(err)}") from None
        except (urllib.error.URLError, OSError) as err:
            raise ProbeError(f"Cognito {target} unreachable: {err}") from None

    def id_token(self, username, password, totp_secret=None):
        """IdToken for a USER_PASSWORD_AUTH login, answering a TOTP challenge if asked."""
        result = self._call("InitiateAuth", {
            "AuthFlow": "USER_PASSWORD_AUTH", "ClientId": self.client_id,
            "AuthParameters": {"USERNAME": username, "PASSWORD": password}})
        challenge = result.get("ChallengeName")
        if challenge == "SOFTWARE_TOKEN_MFA":
            if not totp_secret:
                raise ProbeError("Cognito asked for a TOTP code but no TOTP secret was given "
                                 "(--totp-secret-param or MAIL_PROBE_TOTP_SECRET)")
            result = self._call("RespondToAuthChallenge", {
                "ChallengeName": challenge, "ClientId": self.client_id,
                "Session": result["Session"],
                "ChallengeResponses": {"USERNAME": username,
                                       "SOFTWARE_TOKEN_MFA_CODE": totp_code(totp_secret)}})
        elif challenge:
            raise ProbeError(f"unexpected Cognito challenge {challenge}")
        try:
            return result["AuthenticationResult"]["IdToken"]
        except KeyError:
            raise ProbeError("Cognito returned no IdToken") from None


class Api:
    """The Lambda API behind API Gateway, called the way the clients call it."""

    def __init__(self, invoke_url, token, host):
        self.invoke_url = invoke_url.rstrip("/")
        self.token = token
        self.host = host    # required by every endpoint, ignored server-side

    def call(self, method, path, params=None, body=None):
        """One request; Retryable on 502/503/504 or a socket error, ProbeError otherwise."""
        query = urllib.parse.urlencode({**(params or {}), "host": self.host})
        headers = {"Authorization": self.token}
        data = None
        if body is not None:
            data = json.dumps({**body, "host": self.host}).encode()
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(
            f"{self.invoke_url}/{path}?{query}", data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as err:
            detail = f"{method} /{path} -> {err.code} {error_detail(err)}"
            if err.code in RETRYABLE_STATUSES:
                raise Retryable(detail) from None
            raise ProbeError(detail) from None
        except (urllib.error.URLError, OSError) as err:
            raise Retryable(f"{method} /{path}: {err}") from None
        return json.loads(raw) if raw.strip() else {}


def with_retry(what, deadline, fn):
    """Runs fn, retrying Retryable failures every POLL_INTERVAL until deadline."""
    while True:
        try:
            return fn()
        except Retryable as err:
            if time.monotonic() >= deadline:
                raise ProbeError(f"{what}: gave up after the retry budget: {err}") from None
            log(f"{what}: {err}; retrying in {POLL_INTERVAL}s")
            time.sleep(POLL_INTERVAL)


# -- mailbox helpers ---------------------------------------------------------

def newest_envelopes(api, folder, limit):
    """{uid: envelope} for the newest `limit` messages in `folder`."""
    listing = api.call("GET", "list_messages", {
        "folder": folder, "sort_field": "ARRIVAL", "sort_order": "REVERSE",
        "offset": 0, "limit": limit})
    ids = listing.get("message_ids") or []
    if not ids:
        return {}
    envelopes = api.call("GET", "list_envelopes", {"folder": folder, "ids": json.dumps(ids)})
    return {int(uid): envelope for uid, envelope in (envelopes.get("envelopes") or {}).items()}


def sweep(api, deadline):
    """Moves every probe message in INBOX and Sent to Trash, then purges every
    probe message in Trash. Returns (moved, purged). A folder that cannot be
    listed (Sent does not exist until the first /send) is skipped."""
    moved = 0
    for folder in ("INBOX", "Sent"):
        try:
            found = probe_uids(with_retry(
                f"list {folder}", deadline,
                lambda f=folder: newest_envelopes(api, f, SWEEP_WINDOW)))
        except ProbeError as err:
            log(f"sweep: skipping {folder}: {err}")
            continue
        if not found:
            continue
        result = with_retry(
            f"move {folder} -> Trash", deadline,
            lambda f=folder, ids=sorted(found): api.call(
                "PUT", "move_messages", body={"source": f, "destination": "Trash", "ids": ids}))
        failed = result.get("failed_ids") or []
        if failed:
            log(f"sweep: {len(failed)} message(s) in {folder} could not be moved: {failed}")
        moved += len(found) - len(failed)
    trash = probe_uids(with_retry(
        "list Trash", deadline, lambda: newest_envelopes(api, "Trash", SWEEP_WINDOW)))
    if trash:
        with_retry("purge Trash", deadline, lambda: api.call(
            "DELETE", "purge_messages", body={"folder": "Trash", "ids": sorted(trash)}))
    return moved, len(trash)


def fetch_headers(api, folder, uid, deadline):
    """Parsed headers of one message, via the presigned raw-message URL."""
    fetched = with_retry(
        f"fetch {folder}/{uid}", deadline,
        lambda: api.call("GET", "fetch_message", {"folder": folder, "id": uid}))
    url = fetched.get("message_raw")
    if not url:
        raise ProbeError(f"fetch_message for {folder}/{uid} returned no message_raw URL")
    try:
        with urllib.request.urlopen(url, timeout=60) as resp:
            raw = resp.read()
    except (urllib.error.URLError, OSError) as err:
        raise ProbeError(
            f"could not download the raw message for {folder}/{uid}: {err}") from None
    return BytesHeaderParser().parsebytes(raw)


# -- the two legs ------------------------------------------------------------

def send_via_api(api, address, subject, deadline):
    """PUT /send from the probe address to itself, retrying through a 503 window."""
    body = {"sender": address, "subject": subject, "to_list": [address],
            "cc_list": [], "bcc_list": [], "text": BODY_TEXT, "html": BODY_HTML}
    return with_retry("PUT /send", deadline, lambda: api.call("PUT", "send", body=body))


def resolve_mx(domain):
    """MX hosts for `domain` via dig, lowest preference first; [] if none/unavailable."""
    try:
        result = subprocess.run(["dig", "+short", "MX", domain],
                                capture_output=True, text=True, timeout=30, check=False)
    except (OSError, subprocess.TimeoutExpired) as err:
        log(f"dig unavailable ({err})")
        return []
    return parse_mx(result.stdout)


def _smtp_session(mx_host, verify):
    """A port-25 session, with STARTTLS negotiated when the server offers it."""
    smtp = smtplib.SMTP(mx_host, 25, timeout=SMTP_TIMEOUT)
    try:
        smtp.ehlo()
        if not smtp.has_extn("starttls"):
            return smtp, "not offered"
        context = ssl.create_default_context()
        if not verify:
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
        smtp.starttls(context=context)
        smtp.ehlo()
        return smtp, "verified" if verify else "unverified"
    except Exception:
        smtp.close()
        raise


def send_via_mx(mx_host, address, subject):
    """Delivers to the MX on port 25 like any internet MTA. Returns the TLS mode."""
    message = EmailMessage()
    message["From"] = address
    message["To"] = address
    message["Subject"] = subject
    message["Date"] = format_datetime(datetime.now(timezone.utc))
    message["Message-ID"] = make_msgid(domain=address.rsplit("@", 1)[1])
    message[PROBE_HEADER] = "mail-probe"
    message.set_content(BODY_TEXT)
    for verify in (True, False):
        try:
            smtp, tls = _smtp_session(mx_host, verify)
        except ssl.SSLCertVerificationError as err:
            # An MTA doing opportunistic TLS would carry on unverified too;
            # surface the certificate problem without failing the leg.
            annotate("warning", f"mail probe: STARTTLS certificate check against {mx_host} "
                                f"failed ({err.verify_message}); retrying without verification")
            continue
        except (smtplib.SMTPException, OSError) as err:
            raise ProbeError(
                f"mx leg: could not open an SMTP session with {mx_host}:25: {err}") from None
        try:
            with smtp:
                smtp.send_message(message, from_addr=address, to_addrs=[address])
        except (smtplib.SMTPException, OSError) as err:
            raise ProbeError(f"mx leg: {mx_host} did not accept the message: {err}") from None
        return tls
    raise ProbeError(f"mx leg: STARTTLS with {mx_host} failed even without verification")


def wait_for_delivery(api, expected, deadline):
    """Polls INBOX until every leg's message is there. `expected` maps subject
    to leg; returns {leg: (uid, seen_at)}."""
    seen = {}
    legs = set(expected.values())
    while True:
        envelopes = with_retry("list INBOX", deadline,
                               lambda: newest_envelopes(api, "INBOX", LIST_WINDOW))
        now = time.monotonic()
        for uid, subject in probe_uids(envelopes, set(expected)).items():
            leg = expected[subject]
            if leg not in seen:
                seen[leg] = (uid, now)
                log(f"{leg} leg: delivered, INBOX uid {uid}")
        if set(seen) == legs:
            return seen
        if now >= deadline:
            missing = ", ".join(sorted(legs - set(seen)))
            raise ProbeError(f"not delivered within the reception budget: {missing}")
        time.sleep(POLL_INTERVAL)


def wait_for_sent_copy(api, subject, deadline):
    """Gives /send's queued Sent copy a moment to land so the sweep catches it."""
    while time.monotonic() < deadline:
        try:
            envelopes = newest_envelopes(api, "Sent", LIST_WINDOW)
        except (Retryable, ProbeError):
            envelopes = {}
        if probe_uids(envelopes, {subject}):
            return True
        time.sleep(5)
    return False


def write_summary(label, rows):
    """A small table in the GitHub job summary, when there is one."""
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path:
        return
    with open(path, "a", encoding="utf-8") as summary:
        summary.write(f"### Mail probe `{label}`\n\n| Leg | Delivered in | Evidence |\n|---|---|---|\n")
        for leg, latency, evidence in rows:
            safe = evidence.replace("|", "\\|")
            summary.write(f"| {leg} | {latency:.0f}s | {safe} |\n")


# -- entry point -------------------------------------------------------------

def parse_args(argv):
    parser = argparse.ArgumentParser(
        description="Post-deploy mail probe: send through /send and at the MX, verify in INBOX.")
    parser.add_argument("--control-domain", required=True,
                        help="the environment's control domain (TF_VAR_CONTROL_DOMAIN)")
    parser.add_argument("--username", default=DEFAULT_USERNAME,
                        help=f"Cognito user to sign in as (default {DEFAULT_USERNAME})")
    parser.add_argument("--password-param", default=DEFAULT_PASSWORD_PARAM,
                        help="SSM SecureString holding the password "
                             "(ignored when MAIL_PROBE_PASSWORD is set)")
    parser.add_argument("--totp-secret-param",
                        help="SSM SecureString holding a base32 TOTP secret, for an "
                             "MFA-enrolled user (or set MAIL_PROBE_TOTP_SECRET)")
    parser.add_argument("--address",
                        help="send to this address of the user (default: its first active one)")
    parser.add_argument("--legs", default=",".join(LEGS),
                        help="comma-separated subset of api,mx (default both)")
    parser.add_argument("--mx-host", help="skip the MX lookup and deliver the mx leg here")
    parser.add_argument("--label",
                        help="unique token for this run's subjects (default: GitHub run id, else random)")
    parser.add_argument("--send-budget", type=int, default=180,
                        help="seconds to keep retrying setup calls and /send through a 503 window")
    parser.add_argument("--reception-budget", type=int, default=240,
                        help="seconds to wait for both messages to reach INBOX")
    parser.add_argument("--keep", action="store_true",
                        help="leave the probe messages in the mailbox on success")
    args = parser.parse_args(argv)
    args.legs = [leg.strip() for leg in args.legs.split(",") if leg.strip()]
    if not args.legs or any(leg not in LEGS for leg in args.legs):
        parser.error(f"--legs must be a non-empty subset of {','.join(LEGS)}")
    return args


def default_label():
    run_id = os.environ.get("GITHUB_RUN_ID")
    if run_id:
        return f"{run_id}.{os.environ.get('GITHUB_RUN_ATTEMPT', '1')}"
    return uuid.uuid4().hex[:12]


def run(args):  # pylint: disable=too-many-locals,too-many-branches,too-many-statements
    """The whole probe; raises ProbeError on any failed assertion."""
    label = args.label or default_label()
    config = load_config(args.control_domain)
    password = secret_from("MAIL_PROBE_PASSWORD", args.password_param)
    totp_secret = secret_from("MAIL_PROBE_TOTP_SECRET", args.totp_secret_param)
    token = Cognito(config["region"], config["client_id"]).id_token(
        args.username, password, totp_secret)
    api = Api(config["invoke_url"], token, f"imap.{config['control_domain']}")
    log(f"signed in as {args.username}; legs: {', '.join(args.legs)}; label: {label}")

    setup_deadline = time.monotonic() + args.send_budget
    items = with_retry("GET /list", setup_deadline,
                       lambda: api.call("GET", "list")).get("Items") or []
    address = choose_address(items, args.address)
    log(f"probe address: {address}")
    moved, purged = sweep(api, setup_deadline)
    if moved or purged:
        log(f"pre-sweep: moved {moved} leftover probe message(s) to Trash, purged {purged}")

    subjects = {f"{SUBJECT_PREFIX} {leg} {label}": leg for leg in args.legs}
    by_leg = {leg: subject for subject, leg in subjects.items()}
    sent_at = {}
    if "api" in args.legs:
        result = send_via_api(api, address, by_leg["api"], time.monotonic() + args.send_budget)
        sent_at["api"] = time.monotonic()
        log(f"api leg: /send accepted ({squash(result.get('status', 'ok'))})")
    if "mx" in args.legs:
        domain = address.rsplit("@", 1)[1]
        if args.mx_host:
            mx_host = args.mx_host
        else:
            hosts = resolve_mx(domain)
            mx_host = hosts[0] if hosts else f"smtp-in.{config['control_domain']}"
            if not hosts:
                annotate("warning", f"mail probe: no MX found for {domain}; using {mx_host}")
        tls = send_via_mx(mx_host, address, by_leg["mx"])
        sent_at["mx"] = time.monotonic()
        log(f"mx leg: {mx_host}:25 accepted the message (STARTTLS {tls})")

    seen = wait_for_delivery(api, subjects, time.monotonic() + args.reception_budget)
    verify_deadline = time.monotonic() + 120
    rows = []
    if "api" in seen:
        uid, seen_at = seen["api"]
        domain_tag = dkim_domain(fetch_headers(api, "INBOX", uid, verify_deadline))
        if domain_tag is None:
            raise ProbeError("api leg: the message arrived without a DKIM-Signature header "
                             "(smtp-out did not sign it)")
        rows.append(("api", seen_at - sent_at["api"], f"DKIM-Signature d={domain_tag}"))
    if "mx" in seen:
        uid, seen_at = seen["mx"]
        results = fetch_headers(api, "INBOX", uid, verify_deadline).get_all(
            "Authentication-Results") or []
        if not results:
            raise ProbeError("mx leg: the message arrived without an Authentication-Results "
                             "header (smtp-in's milters did not stamp it)")
        rows.append(("mx", seen_at - sent_at["mx"],
                     f"Authentication-Results: {squash(results[0])}"))
    for leg, latency, evidence in rows:
        log(f"{leg} leg: OK after {latency:.0f}s; {evidence}")
    write_summary(label, rows)

    if args.keep:
        log("--keep: leaving the probe messages in place")
    else:
        try:
            if "api" in args.legs and not wait_for_sent_copy(
                    api, by_leg["api"], time.monotonic() + SENT_COPY_GRACE):
                log("cleanup: the Sent copy has not landed yet; "
                    "the next run's pre-sweep will remove it")
            moved, purged = sweep(api, time.monotonic() + 60)
            log(f"cleanup: moved {moved} to Trash, purged {purged}")
        except ProbeError as err:
            annotate("warning", f"mail probe: cleanup did not finish ({err}); "
                                "the next run's pre-sweep will retry")
    annotate("notice", "mail probe passed: "
             + "; ".join(f"{leg} leg in {latency:.0f}s" for leg, latency, _ in rows))
    return 0


def main(argv=None):
    args = parse_args(argv)
    try:
        return run(args)
    except ProbeError as err:
        annotate("error", f"mail probe failed: {err}")
        return 1
    except KeyboardInterrupt:
        return 130
    except Exception:  # pylint: disable=broad-except
        traceback.print_exc()
        annotate("error", "mail probe crashed; see the traceback above")
        return 1


if __name__ == "__main__":
    sys.exit(main())
