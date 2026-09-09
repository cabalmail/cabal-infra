'''Adaptive fetch cadence for the RSS fetcher (docs/1.x/rss-requirements.md,
Decision 17: the server assesses each feed's velocity and adjusts within
operator-set bounds; nothing is exposed to users).

The estimator is an exponentially weighted moving average of items per day.
The cadence aims for roughly one new item per fetch (1440 / items_per_day
minutes), clamped to [min, max]. Publisher hints - RSS <ttl>, Syndication
updatePeriod/updateFrequency, Cache-Control max-age, Retry-After - are
floors, never ceilings: a publisher may ask us to come back less often, not
more. A feed that fails backs off exponentially from the minimum cadence.

Pure functions, no I/O; exercised by _shared/tests/test_rss_cadence.py.
'''

MINUTES_PER_DAY = 1440
# Weight of the newest observation. 0.3 tracks a feed that changes tempo
# within a few fetches without letting a single burst dominate.
EWMA_ALPHA = 0.3

# Syndication module periods in minutes (http://purl.org/rss/1.0/modules/syndication/).
_SY_PERIOD_MINUTES = {
    'hourly': 60,
    'daily': MINUTES_PER_DAY,
    'weekly': 7 * MINUTES_PER_DAY,
    'monthly': 30 * MINUTES_PER_DAY,
    'yearly': 365 * MINUTES_PER_DAY,
}


def clamp(value, lower, upper):
    '''`value` bounded to [lower, upper].'''
    return max(lower, min(upper, value))


def update_items_per_day(previous, new_items, hours_elapsed):
    '''Next EWMA of items/day after observing `new_items` over `hours_elapsed`.

    `previous` of None means no observation yet, so the first sample is
    taken at face value. A zero or negative interval (clock skew, an
    immediate manual refetch) contributes nothing.'''
    if hours_elapsed is None or hours_elapsed <= 0:
        return previous if previous is not None else 0.0
    observed = new_items / (hours_elapsed / 24.0)
    if previous is None:
        return observed
    return EWMA_ALPHA * observed + (1 - EWMA_ALPHA) * previous


def cadence_from_rate(items_per_day, min_minutes, max_minutes):
    '''Minutes between fetches that yields about one new item per fetch.'''
    if items_per_day is None or items_per_day <= 0:
        return max_minutes
    return int(clamp(round(MINUTES_PER_DAY / items_per_day), min_minutes, max_minutes))


def publisher_floor_minutes(ttl_minutes=None, sy_period=None, sy_frequency=None,
                            max_age_seconds=None, retry_after_seconds=None):
    '''The largest interval the publisher asked for, in minutes, or 0.

    Every hint is optional and malformed values are ignored: a publisher's
    metadata is advice, and bad advice should not stall a feed.'''
    floors = [0]
    floors.append(_as_int(ttl_minutes))
    if sy_period:
        period = _SY_PERIOD_MINUTES.get(str(sy_period).strip().lower())
        frequency = _as_int(sy_frequency) or 1
        if period and frequency > 0:
            floors.append(period // frequency)
    seconds = max(_as_int(max_age_seconds), _as_int(retry_after_seconds))
    floors.append(seconds // 60)
    return max(floors)


def next_cadence_minutes(items_per_day, min_minutes, max_minutes, floor_minutes=0):
    '''The cadence to use next: rate-derived, raised to any publisher floor,
    never above the operator maximum.'''
    cadence = cadence_from_rate(items_per_day, min_minutes, max_minutes)
    return int(clamp(max(cadence, floor_minutes), min_minutes, max_minutes))


def backoff_minutes(consecutive_failures, min_minutes, max_minutes):
    '''Exponential backoff from the minimum cadence: min, 2min, 4min, ...
    capped at the maximum. The first failure retries at the minimum.'''
    exponent = max(0, consecutive_failures - 1)
    try:
        delay = min_minutes * (2 ** exponent)
    except OverflowError:
        delay = max_minutes
    return int(clamp(delay, min_minutes, max_minutes))


def _as_int(value):
    try:
        return max(0, int(float(value)))
    except (TypeError, ValueError):
        return 0
