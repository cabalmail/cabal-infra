'''POST /rss_mark_all_read - mark every item read, per feed, folder, or all.

Body: {"subscription_id": "..."} | {"folder_id": "..."} | {}

Writes each affected subscription's read_watermark (= now): items published
at or before it count as read without a row per item. Items the caller had
explicitly marked unread are flipped, so the result is what the button
promises - nothing unread left.
'''
from datetime import datetime, timezone
from boto3.dynamodb.conditions import Attr, Key  # pylint: disable=import-error
from rss_api import (ROOT_FOLDER, body_of, folder_and_descendants,  # pylint: disable=import-error
                     get_subscription, guarded, list_subscriptions, ok, state,
                     subscriptions, user_feed_key, username)


@guarded
def handler(event, _context):
    '''Watermarks the targeted subscriptions and clears explicit unreads.'''
    user = username(event)
    body = body_of(event)
    if body.get('subscription_id'):
        subs = [get_subscription(user, body['subscription_id'])]
    else:
        subs = list_subscriptions(user)
        if body.get('folder_id'):
            wanted = folder_and_descendants(user, body['folder_id'])
            subs = [s for s in subs if (s.get('folder_id') or ROOT_FOLDER) in wanted]
    now = datetime.now(timezone.utc).isoformat()
    flipped = 0
    for sub in subs:
        subscriptions.update_item(Key={'user': user, 'subscription_id': sub['subscription_id']},
                                  UpdateExpression='SET read_watermark = :now',
                                  ExpressionAttributeValues={':now': now})
        flipped += clear_explicit_unread(user, sub['feed_id'], now)
    return ok({'subscriptions': len(subs), 'flipped': flipped, 'read_watermark': now})


def clear_explicit_unread(user, feed_id, now):
    '''Sets is_read on the caller's rows that explicitly say unread.'''
    key = user_feed_key(user, feed_id)
    kwargs = {'KeyConditionExpression': Key('user_feed').eq(key),
              'FilterExpression': Attr('is_read').eq(False),
              'ProjectionExpression': 'sort_key'}
    flipped = 0
    while True:
        response = state.query(**kwargs)
        for row in response.get('Items', []):
            state.update_item(Key={'user_feed': key, 'sort_key': row['sort_key']},
                              UpdateExpression='SET is_read = :true, updated_at = :now',
                              ExpressionAttributeValues={':true': True, ':now': now})
            flipped += 1
        if 'LastEvaluatedKey' not in response:
            return flipped
        kwargs['ExclusiveStartKey'] = response['LastEvaluatedKey']
