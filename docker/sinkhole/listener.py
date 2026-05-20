#!/usr/bin/env python3
"""SMTP sinkhole test fixture.

A tiny asyncio SMTP listener that returns an operator-selected response
to every RCPT TO. Mode is read from SSM Parameter /cabal/sinkhole_mode
on each new connection, cached for SSM_CACHE_TTL seconds to bound the
API call rate.

Modes:
  defer       421 4.3.2 Service temporarily unavailable on RCPT TO
  bounce      550 5.1.1 User unknown on RCPT TO
  accept      250 OK on RCPT TO, 354/250 on DATA, body discarded
  accept-log  accept + write envelope + headers to stdout (CloudWatch)
  greylist    421 on first attempt from a client IP within 30 min,
              250 on subsequent attempts within that window

Never advertises STARTTLS or PIPELINING; smtp-out falls back to plain.
No authentication. The listener lives on a private subnet, fronted
only by Cloud Map and gated by a Terraform feature flag (var.sinkhole).

See docs/0.9.x/sinkhole-test-harness-plan.md.
"""

import asyncio
import json
import logging
import os
import subprocess
import sys
import time
from typing import Optional

LISTEN_HOST = os.environ.get("SINKHOLE_BIND_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("SINKHOLE_BIND_PORT", "25"))
SSM_PARAM_NAME = os.environ.get("SINKHOLE_MODE_PARAM", "/cabal/sinkhole_mode")
SSM_CACHE_TTL = float(os.environ.get("SINKHOLE_CACHE_TTL", "30"))
GREYLIST_WINDOW = float(os.environ.get("SINKHOLE_GREYLIST_WINDOW", "1800"))
SERVER_NAME = os.environ.get("SINKHOLE_SERVER_NAME", "sinkhole.cabal.internal")

VALID_MODES = {"defer", "bounce", "accept", "accept-log", "greylist"}
DEFAULT_MODE = "defer"

logging.basicConfig(
    level=logging.INFO,
    format="[sinkhole] %(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("sinkhole")

_mode_cache = {"value": DEFAULT_MODE, "expires_at": 0.0}
_greylist_seen: dict[str, float] = {}


def _read_mode_from_ssm() -> str:
    """Fetch the current mode from SSM via the bundled awscli."""
    try:
        result = subprocess.run(
            [
                "aws",
                "ssm",
                "get-parameter",
                "--name",
                SSM_PARAM_NAME,
                "--query",
                "Parameter.Value",
                "--output",
                "text",
            ],
            capture_output=True,
            text=True,
            timeout=5,
            check=True,
        )
        value = result.stdout.strip()
        if value in VALID_MODES:
            return value
        log.warning("ssm value %r not in VALID_MODES; defaulting to %s", value, DEFAULT_MODE)
        return DEFAULT_MODE
    except subprocess.TimeoutExpired:
        log.warning("ssm get-parameter timed out; serving cached/default")
        return _mode_cache.get("value", DEFAULT_MODE)
    except subprocess.CalledProcessError as exc:
        log.warning("ssm get-parameter failed: %s", exc.stderr.strip() if exc.stderr else exc)
        return _mode_cache.get("value", DEFAULT_MODE)
    except (OSError, ValueError) as exc:
        log.warning("ssm fetch error: %s", exc)
        return _mode_cache.get("value", DEFAULT_MODE)


def get_mode() -> str:
    now = time.monotonic()
    if now >= _mode_cache["expires_at"]:
        _mode_cache["value"] = _read_mode_from_ssm()
        _mode_cache["expires_at"] = now + SSM_CACHE_TTL
    return _mode_cache["value"]


def greylist_decision(client_ip: str) -> bool:
    """Return True if this IP should be greylisted (deferred) this attempt."""
    now = time.time()
    for ip, seen_at in list(_greylist_seen.items()):
        if now - seen_at > GREYLIST_WINDOW:
            del _greylist_seen[ip]
    first_seen = _greylist_seen.get(client_ip)
    if first_seen is None:
        _greylist_seen[client_ip] = now
        return True
    return False


class SmtpSession:
    """Minimal RFC 5321 SMTP server-side state machine.

    Implements only what is needed to drive sendmail through HELO/EHLO,
    MAIL FROM, RCPT TO, DATA, RSET, QUIT, NOOP, HELP. No PIPELINING, no
    STARTTLS, no AUTH, no SIZE extension. EHLO answers with no extensions.
    """

    def __init__(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        self.reader = reader
        self.writer = writer
        peer = writer.get_extra_info("peername")
        self.client_ip = peer[0] if peer else "unknown"
        self.helo: Optional[str] = None
        self.mail_from: Optional[str] = None
        self.rcpts: list[str] = []
        self.mode = get_mode()
        self.in_data = False
        self._headers: list[str] = []
        self._in_headers = True

    async def send(self, line: str) -> None:
        self.writer.write((line + "\r\n").encode("utf-8", errors="replace"))
        await self.writer.drain()

    async def banner(self) -> None:
        await self.send(f"220 {SERVER_NAME} ESMTP sinkhole ready")

    async def handle(self) -> None:
        await self.banner()
        try:
            while True:
                raw = await self.reader.readline()
                if not raw:
                    return
                line = raw.decode("utf-8", errors="replace").rstrip("\r\n")
                if self.in_data:
                    if line == ".":
                        self.in_data = False
                        await self._on_end_of_data()
                        self._reset_envelope()
                        continue
                    if self._in_headers:
                        if line == "":
                            self._in_headers = False
                        elif self.mode == "accept-log":
                            # RFC 5321 4.5.2 dot-stuffing: a leading '..'
                            # decodes to '.'.
                            if line.startswith(".."):
                                line = line[1:]
                            self._headers.append(line)
                    continue
                if not await self._dispatch(line):
                    return
        except (ConnectionError, asyncio.IncompleteReadError):
            return
        finally:
            try:
                self.writer.close()
                await self.writer.wait_closed()
            except (ConnectionError, OSError):
                pass

    async def _dispatch(self, line: str) -> bool:
        if not line:
            await self.send("500 5.5.2 Syntax error")
            return True
        verb, _, rest = line.partition(" ")
        verb_upper = verb.upper()
        rest = rest.strip()
        if verb_upper == "QUIT":
            await self.send(f"221 2.0.0 {SERVER_NAME} closing connection")
            return False
        if verb_upper == "NOOP":
            await self.send("250 2.0.0 OK")
            return True
        if verb_upper == "RSET":
            self._reset_envelope()
            await self.send("250 2.0.0 OK")
            return True
        if verb_upper == "HELO":
            self.helo = rest or "unknown"
            await self.send(f"250 {SERVER_NAME}")
            return True
        if verb_upper == "EHLO":
            self.helo = rest or "unknown"
            await self.send(f"250-{SERVER_NAME}")
            await self.send("250 HELP")
            return True
        if verb_upper == "HELP":
            await self.send("214 2.0.0 sinkhole - see docs/0.9.x/sinkhole-test-harness-plan.md")
            return True
        if verb_upper == "VRFY":
            await self.send("252 2.5.2 Cannot VRFY user")
            return True
        if verb_upper == "MAIL":
            return await self._on_mail(rest)
        if verb_upper == "RCPT":
            return await self._on_rcpt(rest)
        if verb_upper == "DATA":
            return await self._on_data()
        await self.send("502 5.5.2 Command not implemented")
        return True

    def _reset_envelope(self) -> None:
        self.mail_from = None
        self.rcpts = []
        self._headers = []
        self._in_headers = True

    async def _on_mail(self, rest: str) -> bool:
        if not rest.upper().startswith("FROM:"):
            await self.send("501 5.5.4 Syntax: MAIL FROM:<address>")
            return True
        addr = rest[5:].strip()
        self.mail_from = addr
        self.rcpts = []
        await self.send("250 2.1.0 Sender OK")
        return True

    async def _on_rcpt(self, rest: str) -> bool:
        if not rest.upper().startswith("TO:"):
            await self.send("501 5.5.4 Syntax: RCPT TO:<address>")
            return True
        if self.mail_from is None:
            await self.send("503 5.5.1 MAIL first")
            return True
        addr = rest[3:].strip()
        # Re-read the mode at RCPT time so an SSM flip during a long-running
        # connection takes effect at the next envelope.
        self.mode = get_mode()
        if self.mode == "defer":
            await self.send("421 4.3.2 Service temporarily unavailable")
            return True
        if self.mode == "bounce":
            await self.send("550 5.1.1 User unknown")
            return True
        if self.mode == "greylist":
            if greylist_decision(self.client_ip):
                await self.send("421 4.7.1 Greylisted; try again later")
                return True
            self.rcpts.append(addr)
            await self.send("250 2.1.5 Recipient OK")
            return True
        self.rcpts.append(addr)
        await self.send("250 2.1.5 Recipient OK")
        return True

    async def _on_data(self) -> bool:
        if not self.rcpts:
            await self.send("503 5.5.1 RCPT first")
            return True
        if self.mode in ("defer", "bounce"):
            await self.send("554 5.5.0 No recipients")
            return True
        await self.send("354 Start mail input; end with <CRLF>.<CRLF>")
        self.in_data = True
        self._headers = []
        self._in_headers = True
        return True

    async def _on_end_of_data(self) -> None:
        if self.mode == "accept-log":
            envelope = {
                "from": self.mail_from,
                "rcpts": self.rcpts,
                "client_ip": self.client_ip,
                "helo": self.helo,
                "headers": self._headers,
            }
            log.info("accepted: %s", json.dumps(envelope))
        await self.send("250 2.0.0 Message accepted for discard")


async def _on_connect(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    session = SmtpSession(reader, writer)
    log.info("connection from %s mode=%s", session.client_ip, session.mode)
    await session.handle()


async def main() -> None:
    server = await asyncio.start_server(_on_connect, LISTEN_HOST, LISTEN_PORT)
    sockets = server.sockets or ()
    bound = ", ".join(str(s.getsockname()) for s in sockets)
    log.info("listening on %s (mode source: ssm %s)", bound, SSM_PARAM_NAME)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        log.info("shutting down")
