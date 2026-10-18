'''POST /rss_mark_all_read - mark every item read, per feed, folder, or all.

Body: {"subscription_id": "..."} | {"folder_id": "..."} | {}, each with an
optional "watermark" (ISO 8601).

Writes each affected subscription's read_watermark: items published at or
before it count as read without a row per item. The watermark is the one
the client sends - the moment the user tapped, which for a mark-all-read
queued offline is earlier than its replay - clamped to now, or now when the
client sends none. A watermark never moves backwards. Items the caller had
explicitly marked unread up to the watermark are flipped, so the result is
what the button promises - nothing unread left that the user had seen.

Only rows that still exist when written are changed: a subscription whose
watermark write finds it gone is skipped (not counted, its state
untouched), and a state row gone by its write is not counted as flipped.
'''
from datetime import datetime, timezone
from boto3.dynamodb.conditions import Attr, Key  # pylint: disable=import-error
from rss_api import (ROOT_FOLDER, ApiError, body_of,  # pylint: disable=import-error
                     folder_and_descendants, get_subscription, guarded,
                     list_subscriptions, ok, state, update_existing,
                     update_subscription_row, updated_key, user_feed_key, username)


@guarded
def handler(event, _context):
    '''Watermarks the targeted subscriptions and clears explicit unreads.'''
    user = username(event)
    body = body_of(event)
    now = datetime.now(timezone.utc)
    watermark = requested_watermark(body.get('watermark'), now)
    if body.get('subscription_id'):
        subs = [get_subscription(user, body['subscription_id'])]
    else:
        subs = list_subscriptions(user)
        if body.get('folder_id'):
            wanted = folder_and_descendants(user, body['folder_id'])
            subs = [s for s in subs if (s.get('folder_id') or ROOT_FOLDER) in wanted]
    stamp = now.isoformat()
    marked = flipped = 0
    for sub in subs:
        if watermark > str(sub.get('read_watermark') or ''):
            written = update_subscription_row(user, sub['subscription_id'],
                                              UpdateExpression='SET read_watermark = :w',
                                              ExpressionAttributeValues={':w': watermark})
            if written is None:
                continue
        marked += 1
        flipped += clear_explicit_unread(user, sub['feed_id'], watermark, stamp)
    return ok({'subscriptions': marked, 'flipped': flipped, 'read_watermark': watermark})


def requested_watermark(raw, now):
    '''The watermark to write, in the server's own format (UTC isoformat, so
    string comparison against stored watermarks and published_at holds):
    the client's tap time when it sent one, never later than now.'''
    if raw is None or raw == '':
        return now.isoformat()
    if not isinstance(raw, str):
        raise ApiError(400, 'invalid_watermark', 'watermark must be an ISO 8601 string.')
    try:
        parsed = datetime.fromisoformat(raw.replace('Z', '+00:00'))
    except ValueError as err:
        raise ApiError(400, 'invalid_watermark', 'watermark must be an ISO 8601 string.') from err
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return min(parsed.astimezone(timezone.utc), now).isoformat()


def clear_explicit_unread(user, feed_id, watermark, now):
    '''Sets is_read on the caller's rows that explicitly say unread, for
    items published at or before the watermark (the sort key leads with
    published_at). Returns how many it flipped; a row gone by the time it
    is written is not written.'''
    key = user_feed_key(user, feed_id)
    kwargs = {'KeyConditionExpression': Key('user_feed').eq(key),
              'FilterExpression': Attr('is_read').eq(False),
              'ProjectionExpression': 'sort_key'}
    flipped = 0
    while True:
        response = state.query(**kwargs)
        for row in response.get('Items', []):
            if row['sort_key'].split('#', 1)[0] > watermark:
                continue
            written = update_existing(
                state, 'sort_key',
                Key={'user_feed': key, 'sort_key': row['sort_key']},
                UpdateExpression='SET is_read = :true, updated_at = :now, updated_key = :ukey',
                ExpressionAttributeValues={':true': True, ':now': now,
                                           ':ukey': updated_key(now, row['sort_key'])})
            if written is not None:
                flipped += 1
        if 'LastEvaluatedKey' not in response:
            return flipped
        kwargs['ExclusiveStartKey'] = response['LastEvaluatedKey']
