'''Unit tests for the pure IMAP connection-pool bookkeeping.

There is no pytest harness in this repo, so this runs under the stdlib:

    python3 lambda/api/_shared/tests/test_imap_pool.py

imap_pool has no third-party deps, so it imports and runs without boto3 /
imapclient / AWS. The pool never touches a connection; a connection here is just
a sentinel string, and we assert on which sentinels come back in `to_close`.'''
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from imap_pool import ImapConnectionPool  # noqa: E402  pylint: disable=wrong-import-position


class FakeClock:
    '''A settable monotonic clock so idle expiry is deterministic.'''

    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


class ImapConnectionPoolTest(unittest.TestCase):

    def setUp(self):
        self.clock = FakeClock()
        self.pool = ImapConnectionPool(max_size=2, idle_seconds=120, clock=self.clock)

    def test_acquire_empty_returns_none(self):
        conn, to_close = self.pool.acquire(('h', 'u'))
        self.assertIsNone(conn)
        self.assertEqual(to_close, [])

    def test_release_then_acquire_returns_same_connection(self):
        self.assertEqual(self.pool.release(('h', 'u'), 'c1'), [])
        conn, to_close = self.pool.acquire(('h', 'u'))
        self.assertEqual(conn, 'c1')
        self.assertEqual(to_close, [])

    def test_acquire_pops_so_second_acquire_is_empty(self):
        self.pool.release(('h', 'u'), 'c1')
        self.pool.acquire(('h', 'u'))
        conn, _ = self.pool.acquire(('h', 'u'))
        self.assertIsNone(conn)

    def test_idle_entry_is_swept_on_acquire(self):
        self.pool.release(('h', 'u'), 'c1')
        self.clock.t += 121  # past idle_seconds
        conn, to_close = self.pool.acquire(('h', 'u'))
        self.assertIsNone(conn)
        self.assertEqual(to_close, ['c1'])

    def test_fresh_entry_within_window_survives(self):
        self.pool.release(('h', 'u'), 'c1')
        self.clock.t += 119  # still inside idle_seconds
        conn, to_close = self.pool.acquire(('h', 'u'))
        self.assertEqual(conn, 'c1')
        self.assertEqual(to_close, [])

    def test_sweep_evicts_other_idle_keys(self):
        self.pool.release(('h', 'a'), 'ca')
        self.clock.t += 200  # ca is now idle
        # Acquiring a DIFFERENT key still sweeps the idle one for disposal.
        conn, to_close = self.pool.acquire(('h', 'b'))
        self.assertIsNone(conn)
        self.assertEqual(to_close, ['ca'])

    def test_release_evicts_lru_over_max_size(self):
        self.assertEqual(self.pool.release(('h', 'a'), 'ca'), [])
        self.assertEqual(self.pool.release(('h', 'b'), 'cb'), [])
        # Third distinct key exceeds max_size=2 -> oldest (ca) is evicted.
        self.assertEqual(self.pool.release(('h', 'c'), 'cc'), ['ca'])
        self.assertIsNone(self.pool.acquire(('h', 'a'))[0])
        self.assertEqual(self.pool.acquire(('h', 'b'))[0], 'cb')
        self.assertEqual(self.pool.acquire(('h', 'c'))[0], 'cc')

    def test_release_refreshes_lru_recency(self):
        self.pool.release(('h', 'a'), 'ca')
        self.pool.release(('h', 'b'), 'cb')
        # Touch 'a' again so 'b' becomes the least-recently-used.
        self.pool.release(('h', 'a'), 'ca2')  # displaces ca for the same key
        # ^ same-key release returns the displaced connection.
        # Now add 'c': it should evict 'b' (now oldest), not the refreshed 'a'.
        self.assertEqual(self.pool.release(('h', 'c'), 'cc'), ['cb'])
        self.assertEqual(self.pool.acquire(('h', 'a'))[0], 'ca2')

    def test_same_key_release_displaces_prior(self):
        self.pool.release(('h', 'u'), 'c1')
        self.assertEqual(self.pool.release(('h', 'u'), 'c2'), ['c1'])
        self.assertEqual(self.pool.acquire(('h', 'u'))[0], 'c2')

    def test_drain_returns_all_and_empties(self):
        self.pool.release(('h', 'a'), 'ca')
        self.pool.release(('h', 'b'), 'cb')
        drained = self.pool.drain()
        self.assertCountEqual(drained, ['ca', 'cb'])
        self.assertIsNone(self.pool.acquire(('h', 'a'))[0])
        self.assertIsNone(self.pool.acquire(('h', 'b'))[0])


if __name__ == '__main__':
    unittest.main()
