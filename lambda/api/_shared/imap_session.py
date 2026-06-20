'''IMAP connection management for the Lambda API: a thin connect/auth/select
wrapper plus the optional warm-invocation connection pool (Phase 7 / Layer 1.5
of the large-mailbox hardening plan).

Split out of helper.py so that module stays under the line cap and so the
connection concern lives on its own. helper.get_imap_client owns the
maintenance-gate check (a planned IMAP roll must short-circuit before we dial a
restarting server) and then delegates here with the master password; this module
owns the IMAP I/O. The pure pool bookkeeping (LRU, idle sweep) lives one layer
down in imap_pool, which has no third-party dependency and is unit-tested.

Off by default. When IMAP_POOL_ENABLED=true, an authenticated IMAPClient is
reused across warm invocations of the same execution environment instead of a
fresh LOGIN+LOGOUT per request, keyed by (host, user). One environment serves
one invocation at a time, so the module-scope pool needs no locking. A held
socket can be silently dead after a freeze/thaw, so entries expire after
POOL_IDLE_SECONDS and the mandatory re-SELECT on checkout doubles as a liveness
probe (reconnect once on failure). The tuning knobs read env with defaults, so
only the on/off flag has to be wired through Terraform.'''
import os
import time
from imapclient import IMAPClient, SocketTimeout  # pylint: disable=import-error
from imapclient.exceptions import IMAPClientError  # pylint: disable=import-error
from imap_pool import ImapConnectionPool  # pylint: disable=import-error

POOL_ENABLED = os.environ.get('IMAP_POOL_ENABLED', 'false').lower() == 'true'
POOL_MAX_SIZE = int(os.environ.get('IMAP_POOL_MAX_SIZE', '8'))
POOL_IDLE_SECONDS = float(os.environ.get('IMAP_POOL_IDLE_SECONDS', '120'))
# Read timeout (s) on POOLED sockets so a silently-dropped connection raises
# instead of wedging the Lambda to the 29s API Gateway ceiling. The flag-off
# path keeps the original no-timeout client, byte-for-byte unchanged.
POOL_SOCKET_TIMEOUT = SocketTimeout(connect=10, read=27)
_imap_pool = ImapConnectionPool(POOL_MAX_SIZE, POOL_IDLE_SECONDS, time.monotonic)


def _new_imap_client(host, user, mpw, timeout=None):
    '''Connects and authenticates a fresh master-user IMAP session.'''
    client = IMAPClient(host=host, use_uid=True, ssl=True, timeout=timeout)
    client.login(f"{user}*admin", mpw)
    return client


def _safe_close(client):
    '''Best-effort, non-blocking teardown of a pooled connection.

    Uses the socket-level shutdown() rather than a graceful LOGOUT on purpose: a
    connection being disposed here is usually idle-swept or probe-failed, i.e.
    likely already dead from a freeze/thaw or NAT eviction. LOGOUT would send the
    command and then BLOCK reading the BYE up to the socket's read timeout (27s)
    before giving up -- unacceptable on the synchronous request path. shutdown()
    does no protocol round trip, so it cannot hang. The authenticated session is
    left for Dovecot to reap on its own idle timeout, the same self-bounding
    outcome as a connection orphaned by a Lambda freeze.'''
    try:
        client.shutdown()
    except Exception:  # pylint: disable=broad-except
        pass


def _close_all(clients):
    '''Closes every connection the pool handed back for disposal.'''
    for client in clients:
        _safe_close(client)


def _checkin(key, client):
    '''Returns a borrowed connection to the pool, closing any it displaces.'''
    _close_all(_imap_pool.release(key, client))


class PooledImapClient:  # pylint: disable=too-few-public-methods
    '''Transparent wrapper returned by open_imap_client when pooling is on.

    Every attribute delegates to the real IMAPClient EXCEPT logout(), which
    checks the connection back into the pool instead of tearing it down. Handlers
    keep calling client.logout() exactly as before; only the meaning of that one
    call changes under the flag. An exception before logout() simply never checks
    the connection in -- it is orphaned and garbage-collected, which is the safe
    outcome (a half-broken connection must not re-enter the pool). Check-in is
    idempotent so a stray double logout() is harmless.'''

    def __init__(self, real, key):
        self._real = real
        self._key = key
        self._released = False

    def logout(self):
        '''Check the connection back into the pool (idempotent).'''
        if self._released:
            return
        self._released = True
        _checkin(self._key, self._real)

    def __enter__(self):
        return self

    def __exit__(self, *_exc):
        self.logout()
        return False

    def __getattr__(self, name):
        # Reached only for attributes the proxy itself doesn't define, i.e.
        # everything other than logout()/_real/_key/_released -> the real client.
        return getattr(self._real, name)


def open_imap_client(host, user, folder, read_only, mpw):
    '''Connects (or reuses a pooled connection) and selects the folder.

    With pooling off (the default) this connects, authenticates, and selects the
    folder exactly as helper.get_imap_client always has, returning a bare
    IMAPClient. With pooling on it returns a PooledImapClient whose logout()
    checks the connection back into a per-(host, user) pool for reuse by the next
    warm invocation. Callers reach this through helper.get_imap_client, which
    applies the maintenance gate first.'''
    if not POOL_ENABLED:
        client = IMAPClient(host=host, use_uid=True, ssl=True)
        client.login(f"{user}*admin", mpw)
        client.select_folder(folder, read_only)
        return client
    return _get_pooled_imap_client(host, user, folder, read_only, mpw)


def _get_pooled_imap_client(host, user, folder, read_only, mpw):
    '''Pooled variant: reuse a warm session if one is live, otherwise reconnect.
    The re-SELECT both sets the requested mailbox (a reused connection may have
    been checked in on a different folder -- it is never safe to trust its last
    SELECT) and serves as a liveness probe.'''
    key = (host, user)
    reused, to_close = _imap_pool.acquire(key)
    _close_all(to_close)
    if reused is not None:
        try:
            reused.select_folder(folder, read_only)
            return PooledImapClient(reused, key)
        except (IMAPClientError, OSError):
            _safe_close(reused)  # dead/stale -- fall through and reconnect once
    client = _new_imap_client(host, user, mpw, POOL_SOCKET_TIMEOUT)
    try:
        client.select_folder(folder, read_only)
    except Exception:  # pylint: disable=broad-except
        _safe_close(client)  # don't leak an authenticated session on failure
        raise
    return PooledImapClient(client, key)
