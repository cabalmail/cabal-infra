#!/usr/bin/env python3
'''Performs keyworded maildir deliveries via IMAP APPEND (imap tier).

Decision 5 of docs/1.x/rules-composition-and-custom-flags-plan.md (and its
2026-08-28 erratum): custom flags are IMAP keywords, and the per-folder
keyword-letter mapping (dovecot-keywords) is Dovecot-owned state the raw
Maildir write in cabal-maildir-deliver.sh must never race. When a delivery
carries keywords, the helper - running as the recipient from a
sendmail-sanitized environment, so it can hold no credential - spools the
message plus a request file here and waits, bounded, for a response file.
This daemon, started by supervisord as root so it inherits MASTER_PASSWORD
from the container environment, performs the APPEND to the loopback
Dovecot as {user}*admin and writes the response. The split keeps the
master credential (which opens every mailbox) away from per-user delivery
agents - the same spool/drain posture as push-spool-drain.sh and
cabal-forward-drain.sh - while the synchronous response wait preserves the
helper's procmail `w` contract: a failed APPEND falls through to an
undecorated delivery, never a lost message.

Request protocol (spool dir is sticky world-writable, like the siblings):
the helper writes <nonce>.msg (raw message bytes) then <nonce>.json
({"user", "folder", "flags"}), the JSON written under a dot-prefixed name
and renamed to commit. This daemon CLAIMS a request by renaming the .json
to .work.<nonce>.json before touching it - the rename is what lets the
helper distinguish "drain is on it, keep waiting" from "drain never saw
it, safe to withdraw", which is what makes delivery at-most-once across
the helper's timeout (a request withdrawn before the claim can never be
delivered late; a claimed request always gets its response). It
authenticates by file ownership - both files must be owned by the user
the request names (or by root, for the pre-DROPPRIVS pass) - answers
with <nonce>.resp containing "ok" or "fail", and deletes the request
files. Responses and orphaned spool files (including .work files from a
crash mid-request) are aged out.
'''
import json
import os
import pwd
import re
import socket
import ssl
import sys
import time
import imaplib

SPOOL_DIR = '/var/spool/cabal-append'
POLL_SECONDS = 0.2
# A delivery request loses its point once the helper's wait (20s) has
# expired; responses linger only until the helper collects them.
MAX_REQUEST_AGE_SECONDS = 60
MAX_RESPONSE_AGE_SECONDS = 300
IMAP_TIMEOUT_SECONDS = 15

USER_RE = re.compile(r'^[A-Za-z0-9._-]+$')
# IMAP folder names as the compiler resolves them: dotted internal form
# without the leading dot ('INBOX' for the root), same charset the
# compiler's FOLDER_SAFE_RE admits.
FOLDER_RE = re.compile(r'^[A-Za-z0-9._ -]+$')
# The deliverable flag vocabulary: the two Maildir system flags the rules
# engine can set, plus the fixed palette slot atoms (decision 4).
SYSTEM_FLAGS = {'\\Seen', '\\Flagged'}
SLOT_RE = re.compile(r'^cabal-flag-(0[1-9]|1[0-9]|20)$')
MAX_FLAGS = 22


def validate_request(meta, owner):
    '''Returns an error string, or None for a request safe to deliver.'''
    if not isinstance(meta, dict):
        return 'not an object'
    user = meta.get('user')
    if not isinstance(user, str) or not USER_RE.match(user):
        return 'bad user'
    if owner not in ('root', user):
        return f'owner {owner!r} does not match user {user!r}'
    folder = meta.get('folder')
    if not isinstance(folder, str) or not FOLDER_RE.match(folder) \
            or folder.startswith('.') or '..' in folder:
        return 'bad folder'
    flags = meta.get('flags')
    if not isinstance(flags, list) or not flags:
        return 'bad flags'
    for flag in flags:
        if not isinstance(flag, str):
            return 'bad flags'
        if flag not in SYSTEM_FLAGS and not SLOT_RE.match(flag):
            return f'flag not deliverable: {flag!r}'
    # Dedupe before the cap: rule-own and pending keyword unions may repeat
    # a slot (Phase 5), and 22 is the distinct-vocabulary bound (20 slots +
    # 2 system flags), not a token count.
    meta['flags'] = list(dict.fromkeys(flags))
    if len(meta['flags']) > MAX_FLAGS:
        return 'bad flags'
    return None


def imap_flag_list(flags):
    '''The parenthesized APPEND flag list; inputs pre-validated above.'''
    return '(' + ' '.join(flags) + ')'


def quoted_mailbox(folder):
    '''Quotes the mailbox name for APPEND (imaplib does not); the folder
    charset admits spaces but no quotes or backslashes, so plain quoting
    is complete.'''
    return f'"{folder}"'


class _LoopbackIMAP(imaplib.IMAP4):
    '''Dials 127.0.0.1:143 while carrying the public IMAP name, so STARTTLS
    verifies the wildcard certificate against imap.<control-domain> - the
    same split the Lambda's internal route uses.'''

    def _create_socket(self, timeout):
        return socket.create_connection(
            ('127.0.0.1', 143),
            timeout if timeout and timeout > 0 else IMAP_TIMEOUT_SECONDS)


def open_client(cert_domain, factory=_LoopbackIMAP):
    '''STARTTLS-secured loopback connection, hostname-verified.

    Verification uses the SYSTEM trust store (the served certificate is a
    public wildcard, verified the same way the Lambda's internal route
    verifies it) with the tier's rendered CA bundle added on top - added,
    not substituted: passing the bundle as `cafile` to
    create_default_context REPLACES the root store, and the bundle holds
    the issuing intermediates without their root, which fails every
    handshake with "unable to get issuer certificate" (observed on stage).
    '''
    context = ssl.create_default_context()
    try:
        context.load_verify_locations(
            cafile=f'/etc/pki/tls/certs/{cert_domain}.ca-bundle')
    except (OSError, ssl.SSLError):
        pass  # system roots alone verify the public chain
    client = factory(f'imap.{cert_domain}', timeout=IMAP_TIMEOUT_SECONDS)
    client.starttls(context)
    return client


def append_message(client, meta, message, master_password):
    '''Logs in as the master user and APPENDs; raises on any failure.'''
    client.login(f"{meta['user']}*admin", master_password)
    try:
        status, _data = client.append(
            quoted_mailbox(meta['folder']), imap_flag_list(meta['flags']),
            None, message)
        if status != 'OK':
            raise RuntimeError(f'APPEND {status}')
    finally:
        try:
            client.logout()
        except (OSError, imaplib.IMAP4.error):
            pass


def _respond(nonce, verdict):
    '''Writes the response file the helper is polling for (world-readable;
    the spool is sticky, so only root and the requester can remove it).'''
    tmp = os.path.join(SPOOL_DIR, f'.tmp.{nonce}.resp')
    with open(tmp, 'w', encoding='ascii') as handle:
        handle.write(verdict + '\n')
    os.chmod(tmp, 0o644)
    os.replace(tmp, os.path.join(SPOOL_DIR, f'{nonce}.resp'))


def handle_request(meta_path, cert_domain, master_password,
                   client_factory=None):
    '''Processes one claimed request file; always answers and cleans up.'''
    nonce = os.path.basename(meta_path)[len('.work.'):-len('.json')]
    msg_path = os.path.join(SPOOL_DIR, f'{nonce}.msg')
    verdict = 'fail'
    started = time.monotonic()
    try:
        owner_uid = os.stat(meta_path).st_uid
        with open(meta_path, encoding='utf-8') as handle:
            meta = json.load(handle)
        # Both halves must come from the claimed user (or root).
        owner = pwd.getpwuid(owner_uid).pw_name
        error = validate_request(meta, owner)
        if error is None and os.stat(msg_path).st_uid != owner_uid:
            error = 'message file owner mismatch'
        if error is None:
            with open(msg_path, 'rb') as handle:
                message = handle.read()
            if not message:
                error = 'empty message'
        if error is None:
            client = (client_factory or open_client)(cert_domain)
            append_message(client, meta, message, master_password)
            verdict = 'ok'
            print(f'[cabal-append-drain] delivered {nonce} '
                  f"user={meta['user']} folder={meta['folder']} "
                  f'in {time.monotonic() - started:.1f}s', flush=True)
        else:
            print(f'[cabal-append-drain] rejecting {nonce}: {error}',
                  flush=True)
    except Exception as err:  # pylint: disable=broad-exception-caught
        # One bad request must never take the drain down; the helper's
        # timeout turns silence into a fall-through anyway, but answer
        # when we can so it falls through fast.
        print(f'[cabal-append-drain] {nonce} failed: {err}', flush=True)
    for path in (meta_path, msg_path):
        try:
            os.unlink(path)
        except OSError:
            pass
    try:
        _respond(nonce, verdict)
    except OSError as err:
        print(f'[cabal-append-drain] respond {nonce} failed: {err}',
              flush=True)
    return verdict


def sweep_stale():
    '''Ages out responses nobody collected and orphaned spool halves.'''
    now = time.time()
    try:
        entries = os.listdir(SPOOL_DIR)
    except OSError:
        return
    for name in entries:
        path = os.path.join(SPOOL_DIR, name)
        # .work files only outlive a drain crash mid-request; ordinary
        # requests and responses age out on their own clocks.
        limit = (MAX_RESPONSE_AGE_SECONDS if name.endswith('.resp')
                 else MAX_REQUEST_AGE_SECONDS)
        try:
            if now - os.stat(path).st_mtime > limit:
                os.unlink(path)
        except OSError:
            pass


def main():
    '''Drains committed requests forever; supervisord owns the lifecycle.'''
    cert_domain = os.environ.get('CERT_DOMAIN', '')
    master_password = os.environ.get('MASTER_PASSWORD', '')
    if not cert_domain or not master_password:
        # Idle RUNNING rather than exit (autorestart would just loop us).
        print('[cabal-append-drain] CERT_DOMAIN/MASTER_PASSWORD not set; '
              'keyworded delivery disabled, idling.', flush=True)
        while True:
            time.sleep(3600)
    os.makedirs(SPOOL_DIR, exist_ok=True)
    os.chmod(SPOOL_DIR, 0o1777)
    print(f'[cabal-append-drain] Draining {SPOOL_DIR}', flush=True)
    last_sweep = 0.0
    while True:
        for name in sorted(os.listdir(SPOOL_DIR)):
            if not name.endswith('.json') or name.startswith('.'):
                continue
            # Claim before touching: the rename tells a timing-out helper
            # the request is in flight (keep waiting) versus never seen
            # (safe to withdraw). A helper that withdrew first makes this
            # rename fail - then there is nothing to do.
            claimed = os.path.join(SPOOL_DIR, f'.work.{name}')
            try:
                os.rename(os.path.join(SPOOL_DIR, name), claimed)
            except OSError:
                continue
            handle_request(claimed, cert_domain, master_password)
        if time.time() - last_sweep > 30:
            sweep_stale()
            last_sweep = time.time()
        time.sleep(POLL_SECONDS)


if __name__ == '__main__':
    sys.exit(main())
