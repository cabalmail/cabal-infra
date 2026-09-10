'''POST /rss_unsubscribe - remove one of the caller's subscriptions.

Body: {"subscription_id": "..."}

Deletes the subscription and the caller's per-item state for that feed.
When the feed's subscriber count reaches zero (D4, revised 2026-09-09) the
feed row, its items, and any spilled bodies are deleted too - the feed is
then gone until someone subscribes again, at which point it starts fresh.
Deletion is bounded per call (PURGE_ITEM_LIMIT); a feed larger than that is
left idle (out of the by_due index, subscriber_count 0) with a log line
for the operator to sweep.
'''
import os
from boto3.dynamodb.conditions import Key  # pylint: disable=import-error
from botocore.exceptions import ClientError  # pylint: disable=import-error
from rss_api import (CACHE_BUCKET, ITEM_TABLE, body_of, feeds,  # pylint: disable=import-error
                     get_subscription, guarded, items, ok, s3, state,
                     subscriptions, user_feed_key, username)

PURGE_ITEM_LIMIT = int(os.environ.get('RSS_PURGE_ITEM_LIMIT', '5000'))


@guarded
def handler(event, _context):
    '''Removes the subscription, the caller's state, and an orphaned feed.'''
    user = username(event)
    body = body_of(event)
    sub = get_subscription(user, body.get('subscription_id'))
    # State first: if that fails the subscription still exists and a retry
    # finishes the job, whereas the reverse order strands state rows that
    # would resurface on a later re-subscribe (seen on stage 2026-09-09).
    delete_state(user, sub['feed_id'])
    subscriptions.delete_item(Key={'user': user, 'subscription_id': sub['subscription_id']})
    remaining = detach_subscriber(sub['feed_id'])
    purged = False
    if remaining is not None and remaining <= 0:
        purged = purge_feed(sub['feed_id'])
    return ok({'subscription_id': sub['subscription_id'], 'feed_id': sub['feed_id'],
               'feed_purged': purged})


def delete_state(user, feed_id):
    '''Drops every state row the caller holds for the feed.'''
    key = user_feed_key(user, feed_id)
    kwargs = {'KeyConditionExpression': Key('user_feed').eq(key),
              'ProjectionExpression': 'sort_key'}
    with state.batch_writer() as batch:
        while True:
            response = state.query(**kwargs)
            for row in response.get('Items', []):
                batch.delete_item(Key={'user_feed': key, 'sort_key': row['sort_key']})
            if 'LastEvaluatedKey' not in response:
                return
            kwargs['ExclusiveStartKey'] = response['LastEvaluatedKey']


def detach_subscriber(feed_id):
    '''Decrements subscriber_count; returns the new value, or None when the
    feed row is already gone.'''
    try:
        response = feeds.update_item(
            Key={'feed_id': feed_id},
            UpdateExpression='ADD subscriber_count :minus',
            ConditionExpression='attribute_exists(feed_id)',
            ExpressionAttributeValues={':minus': -1},
            ReturnValues='UPDATED_NEW')
    except ClientError as err:
        if err.response['Error']['Code'] == 'ConditionalCheckFailedException':
            return None
        raise
    return int(response.get('Attributes', {}).get('subscriber_count', 0))


def purge_feed(feed_id):
    '''Deletes the feed's items, spilled bodies, and row. False if the item
    count exceeded the per-call bound (the feed is left idle instead).'''
    # Leave the by_due index first so no fetch races the deletion.
    feeds.update_item(Key={'feed_id': feed_id},
                      UpdateExpression='REMOVE due_shard SET subscriber_count = :zero',
                      ExpressionAttributeValues={':zero': 0})
    deleted = 0
    kwargs = {'KeyConditionExpression': Key('feed_id').eq(feed_id),
              'ProjectionExpression': 'sort_key, content_s3_key'}
    with items.batch_writer() as batch:
        while True:
            response = items.query(**kwargs)
            for row in response.get('Items', []):
                if deleted >= PURGE_ITEM_LIMIT:
                    print(f'[rss-unsubscribe] {feed_id} exceeds {PURGE_ITEM_LIMIT} items; '
                          f'left idle for an operator sweep')
                    return False
                if row.get('content_s3_key'):
                    s3.delete_object(Bucket=CACHE_BUCKET, Key=row['content_s3_key'])
                batch.delete_item(Key={'feed_id': feed_id, 'sort_key': row['sort_key']})
                deleted += 1
            if 'LastEvaluatedKey' not in response:
                break
            kwargs['ExclusiveStartKey'] = response['LastEvaluatedKey']
    feeds.delete_item(Key={'feed_id': feed_id})
    print(f'[rss-unsubscribe] purged {feed_id}: {deleted} items from {ITEM_TABLE}')
    return True
