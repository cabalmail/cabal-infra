'''In-execution-environment IMAP connection pool (Phase 7 / Layer 1.5 of the
large-mailbox hardening plan).

This module is pure bookkeeping: it holds opaque connection objects keyed by a
hashable key (the helper uses ``(host, user)``) and decides which to hand back
and which to discard. It knows NOTHING about IMAP -- no login, no SELECT, no
socket -- so it stays importable and unit-testable without boto3/imapclient or
any AWS dependency. ``helper.py`` injects the clock and owns every bit of IMAP
I/O: connecting, the re-SELECT that doubles as a liveness probe, and the
best-effort close of whatever this pool tells it to discard.

Why a module-scope pool is safe in Lambda: one execution environment serves at
most one invocation at a time, so this state needs no locking. Why entries
expire: a connection held across a freeze/thaw can be silently dead (Dovecot's
~30 min idle timeout, or NAT-instance conntrack eviction, or the freeze itself),
so every entry carries a last-used stamp and the pool evicts anything idle past
``idle_seconds``. The caller still treats the mandatory re-SELECT after checkout
as a liveness probe and reconnects once on failure, covering the residual race
where a within-window connection died anyway.

The pool never closes a connection itself. Every method that drops a connection
returns it in a ``to_close`` list; the caller is responsible for closing those
(best-effort), which keeps all IMAP/socket handling on the helper side.'''


class ImapConnectionPool:
    '''A tiny LRU pool of opaque, already-authenticated connection objects.

    ``max_size`` bounds how many distinct keys a single warm environment retains
    (one environment can serve many users over its lifetime), and
    ``idle_seconds`` bounds how long a connection may sit unused before it is
    assumed dead. ``clock`` is a zero-arg callable returning a monotonic-ish
    float (``time.monotonic`` in production, a fake in tests).'''

    def __init__(self, max_size, idle_seconds, clock):
        self._max_size = max_size
        self._idle_seconds = idle_seconds
        self._clock = clock
        # key -> [connection, last_used]. Dict insertion order is the LRU order:
        # acquire() pops, release() re-inserts at the end, so the oldest key is
        # always first.
        self._entries = {}

    def acquire(self, key):
        '''Pop and return the live connection for ``key``, or ``None``.

        Returns ``(connection_or_None, to_close)``. Sweeps EVERY idle-expired
        entry first (not just ``key``'s) so a busy environment cycling through
        many users does not accumulate dead sockets, then pops the surviving
        entry for ``key`` if there is one.'''
        now = self._clock()
        to_close = self._sweep_idle(now)
        entry = self._entries.pop(key, None)
        if entry is None:
            return None, to_close
        return entry[0], to_close

    def release(self, key, connection):
        '''Store ``connection`` back under ``key`` as most-recently-used.

        Returns the ``to_close`` list: any connection displaced for the same key
        (defensive -- one invocation at a time means this is normally empty)
        plus any least-recently-used connection evicted to honor ``max_size``.'''
        now = self._clock()
        to_close = []
        prior = self._entries.pop(key, None)
        if prior is not None:
            to_close.append(prior[0])
        self._entries[key] = [connection, now]
        while len(self._entries) > self._max_size:
            oldest_key = next(iter(self._entries))
            to_close.append(self._entries.pop(oldest_key)[0])
        return to_close

    def drain(self):
        '''Empty the pool, returning every connection for the caller to close.'''
        conns = [entry[0] for entry in self._entries.values()]
        self._entries.clear()
        return conns

    def _sweep_idle(self, now):
        to_close = []
        for key in list(self._entries.keys()):
            connection, last_used = self._entries[key]
            if now - last_used > self._idle_seconds:
                del self._entries[key]
                to_close.append(connection)
        return to_close
