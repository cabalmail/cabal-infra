'''Unit tests for rss_cadence - the adaptive fetch cadence (Decision 17).

    python3 lambda/api/_shared/tests/test_rss_cadence.py
'''
import os
import sys
import unittest

_SHARED = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, _SHARED)

import rss_cadence as rc  # noqa: E402  pylint: disable=wrong-import-position


class ItemsPerDay(unittest.TestCase):

    def test_first_observation_taken_at_face_value(self):
        self.assertAlmostEqual(rc.update_items_per_day(None, 6, 24), 6.0)

    def test_ewma_blends(self):
        self.assertAlmostEqual(rc.update_items_per_day(10.0, 0, 24), 7.0)
        self.assertAlmostEqual(rc.update_items_per_day(0.0, 24, 24), 7.2)

    def test_zero_interval_changes_nothing(self):
        self.assertEqual(rc.update_items_per_day(5.0, 3, 0), 5.0)
        self.assertEqual(rc.update_items_per_day(None, 3, None), 0.0)


class Cadence(unittest.TestCase):

    def test_one_item_per_fetch(self):
        self.assertEqual(rc.cadence_from_rate(24, 15, 1440), 60)
        self.assertEqual(rc.cadence_from_rate(1, 15, 1440), 1440)

    def test_clamped_to_bounds(self):
        self.assertEqual(rc.cadence_from_rate(1000, 15, 1440), 15)
        self.assertEqual(rc.cadence_from_rate(0.001, 15, 1440), 1440)
        self.assertEqual(rc.cadence_from_rate(0, 15, 1440), 1440)
        self.assertEqual(rc.cadence_from_rate(None, 15, 1440), 1440)

    def test_publisher_floor_raises_but_never_exceeds_max(self):
        self.assertEqual(rc.next_cadence_minutes(24, 15, 1440, floor_minutes=120), 120)
        self.assertEqual(rc.next_cadence_minutes(24, 15, 1440, floor_minutes=99999), 1440)
        self.assertEqual(rc.next_cadence_minutes(24, 15, 1440, floor_minutes=0), 60)


class Floors(unittest.TestCase):

    def test_ttl_and_sy(self):
        self.assertEqual(rc.publisher_floor_minutes(ttl_minutes=90), 90)
        self.assertEqual(rc.publisher_floor_minutes(sy_period='hourly', sy_frequency=2), 30)
        self.assertEqual(rc.publisher_floor_minutes(sy_period='daily'), 1440)
        self.assertEqual(rc.publisher_floor_minutes(sy_period='fortnightly'), 0)

    def test_http_hints_in_seconds(self):
        self.assertEqual(rc.publisher_floor_minutes(max_age_seconds=3600), 60)
        self.assertEqual(rc.publisher_floor_minutes(retry_after_seconds=7200), 120)
        self.assertEqual(rc.publisher_floor_minutes(max_age_seconds=3600, retry_after_seconds=7200), 120)

    def test_garbage_ignored(self):
        self.assertEqual(rc.publisher_floor_minutes(ttl_minutes='soon', sy_frequency='x'), 0)
        self.assertEqual(rc.publisher_floor_minutes(ttl_minutes=-5), 0)


class Backoff(unittest.TestCase):

    def test_exponential_from_minimum(self):
        self.assertEqual([rc.backoff_minutes(n, 15, 1440) for n in (1, 2, 3, 4)], [15, 30, 60, 120])

    def test_capped(self):
        self.assertEqual(rc.backoff_minutes(20, 15, 1440), 1440)
        self.assertEqual(rc.backoff_minutes(5000, 15, 1440), 1440)
        self.assertEqual(rc.backoff_minutes(0, 15, 1440), 15)


if __name__ == '__main__':
    unittest.main()
