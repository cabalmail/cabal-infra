#!/usr/bin/env python3
"""Send a test email on a fixed cadence (default: every 20 minutes for 24 hours).

Connects directly to the smtp-out submission listener (587 STARTTLS or 465
implicit TLS) and authenticates as a normal Cognito user via Dovecot SASL.
This deliberately bypasses the /send Lambda so the loop exercises the
SMTP submission path that desktop/mobile mail clients use.

Required env vars:

  SMTP_USERNAME    Cognito username (the SASL login)
  SMTP_PASSWORD    Cognito password

Required args:

  --from           From: address (must belong to SMTP_USERNAME)
  --to             To: address

Optional env vars / args (env shown in parens):

  --host           (SMTP_HOST)  submission host, e.g. smtp-out.cabalmail.com
  --port           (SMTP_PORT)  default 587 (STARTTLS); use 465 for implicit TLS
  --interval-minutes            default 20
  --duration-hours              default 24
  --once                        send a single message and exit (for smoke testing)

Example:

  export SMTP_USERNAME='alice'
  export SMTP_PASSWORD='...'
  export SMTP_HOST='smtp-out.cabalmail.com'
  ./scripts/test-mail-loop.py \\
      --from probe@mail-admin.cabalmail.com \\
      --to   alice@inbox.cabalmail.com
"""

import argparse
import os
import signal
import smtplib
import ssl
import sys
import time
from datetime import datetime, timezone
from email.message import EmailMessage
from email.utils import format_datetime, make_msgid

LOG_TAG = "[test-mail-loop]"

LOREM = (
    "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod "
    "tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim "
    "veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea "
    "commodo consequat. Duis aute irure dolor in reprehenderit in voluptate "
    "velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint "
    "occaecat cupidatat non proident, sunt in culpa qui officia deserunt "
    "mollit anim id est laborum."
)


def log(msg, *, stream=sys.stdout):
    stamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
    print(f"{LOG_TAG} {stamp} {msg}", file=stream, flush=True)


def parse_args():
    p = argparse.ArgumentParser(
        description="Send a lorem-ipsum test email on a fixed cadence.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--from", dest="sender", required=True, help="From: address")
    p.add_argument("--to", dest="recipient", required=True, help="To: address")
    p.add_argument(
        "--host",
        default=os.environ.get("SMTP_HOST"),
        help="SMTP submission host (env SMTP_HOST)",
    )
    p.add_argument(
        "--port",
        type=int,
        default=int(os.environ.get("SMTP_PORT", "587")),
        help="SMTP submission port (env SMTP_PORT, default 587)",
    )
    p.add_argument(
        "--interval-minutes",
        type=int,
        default=20,
        help="Minutes between sends (default 20)",
    )
    p.add_argument(
        "--duration-hours",
        type=float,
        default=24.0,
        help="Total duration in hours (default 24)",
    )
    p.add_argument(
        "--once",
        action="store_true",
        help="Send one message and exit (ignores --duration-hours)",
    )
    return p.parse_args()


def build_message(sender, recipient, sequence, total):
    msg = EmailMessage()
    msg["Subject"] = f"test-mail-loop {sequence}/{total} - lorem ipsum"
    msg["From"] = sender
    msg["To"] = recipient
    msg["Date"] = format_datetime(datetime.now(timezone.utc))
    msg["Message-ID"] = make_msgid(domain=sender.split("@", 1)[-1])
    msg["X-Cabal-Test-Probe"] = "test-mail-loop"
    msg["X-Cabal-Test-Sequence"] = f"{sequence}/{total}"
    msg.set_content(f"Probe message {sequence} of {total}.\n\n{LOREM}\n")
    return msg


def send_one(host, port, username, password, msg):
    ctx = ssl.create_default_context()
    if port == 465:
        with smtplib.SMTP_SSL(host, port, context=ctx, timeout=30) as s:
            s.login(username, password)
            s.send_message(msg)
    else:
        with smtplib.SMTP(host, port, timeout=30) as s:
            s.ehlo()
            s.starttls(context=ctx)
            s.ehlo()
            s.login(username, password)
            s.send_message(msg)


def main():
    args = parse_args()

    if not args.host:
        sys.exit(f"{LOG_TAG} SMTP host required: --host or SMTP_HOST")

    username = os.environ.get("SMTP_USERNAME")
    password = os.environ.get("SMTP_PASSWORD")
    if not username or not password:
        sys.exit(f"{LOG_TAG} SMTP_USERNAME and SMTP_PASSWORD env vars required")

    if args.interval_minutes <= 0:
        sys.exit(f"{LOG_TAG} --interval-minutes must be positive")
    if args.duration_hours <= 0:
        sys.exit(f"{LOG_TAG} --duration-hours must be positive")

    interval_seconds = args.interval_minutes * 60
    total_seconds = args.duration_hours * 3600

    if args.once:
        total = 1
    else:
        # Sends at t=0, interval, 2*interval, ... while strictly less than duration.
        total = int(total_seconds // interval_seconds)
        if total < 1:
            total = 1

    # Graceful Ctrl-C: finish the in-flight send, then exit.
    stop = {"flag": False}

    def handle_sigint(_signum, _frame):
        stop["flag"] = True
        log("SIGINT received - will exit after current iteration")

    signal.signal(signal.SIGINT, handle_sigint)
    signal.signal(signal.SIGTERM, handle_sigint)

    log(
        f"plan: {total} message(s) from {args.sender} to {args.recipient} "
        f"via {args.host}:{args.port}, interval {args.interval_minutes}m"
    )

    start = time.monotonic()
    sent = 0
    failed = 0

    for i in range(total):
        target = start + i * interval_seconds
        wait = target - time.monotonic()
        while wait > 0 and not stop["flag"]:
            # Sleep in chunks so SIGINT is responsive.
            time.sleep(min(wait, 5))
            wait = target - time.monotonic()
        if stop["flag"]:
            break

        seq = i + 1
        msg = build_message(args.sender, args.recipient, seq, total)
        try:
            send_one(args.host, args.port, username, password, msg)
            sent += 1
            log(f"sent {seq}/{total} message-id={msg['Message-ID']}")
        except (smtplib.SMTPException, OSError, ssl.SSLError) as exc:
            failed += 1
            log(f"send {seq}/{total} FAILED: {exc}", stream=sys.stderr)

    log(f"done: sent={sent} failed={failed} of {total}")
    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
