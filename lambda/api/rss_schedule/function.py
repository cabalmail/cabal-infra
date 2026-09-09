'''RSS fetch scheduler (docs/1.x/rss-implementation-plan.md, phase 2).

Fires every five minutes from EventBridge Scheduler. Queries the sparse
by_due index of cabal-rss-feed for feeds whose next_fetch_at has passed,
claims each one with a conditional update that pushes next_fetch_at out by
a short lease, and enqueues its feed_id on cabal-rss-fetch-queue for the
rss_fetch worker. The claim is what makes a slow tick, a duplicated tick,
or a lost message harmless: the same feed cannot be enqueued twice inside
the lease, and a feed whose message is never consumed simply comes due
again when the lease lapses.

Not an API endpoint. See terraform/infra/modules/app/rss_fetcher.tf.
'''
import json
import os
import time
from datetime import datetime, timedelta, timezone
import boto3  # pylint: disable=import-error
from botocore.exceptions import ClientError  # pylint: disable=import-error
from boto3.dynamodb.conditions import Key  # pylint: disable=import-error

FEED_TABLE = 'cabal-rss-feed'
QUEUE_URL = os.environ['FETCH_QUEUE_URL']
# How long a claim holds before the feed is considered due again. Longer
# than the worker's timeout plus queue visibility, so a live fetch is never
# re-enqueued; short enough that a lost message costs one lease, not a day.
CLAIM_LEASE_MINUTES = int(os.environ.get('CLAIM_LEASE_MINUTES', '30'))
# Upper bound per tick; the rest come due on the next tick five minutes on.
MAX_FEEDS_PER_TICK = int(os.environ.get('MAX_FEEDS_PER_TICK', '500'))

ddb = boto3.resource('dynamodb')
table = ddb.Table(FEED_TABLE)
sqs = boto3.client('sqs')


def handler(_event, _context):
    '''Claims every due feed and enqueues it for fetching.'''
    now = datetime.now(timezone.utc)
    now_iso = now.isoformat()
    lease_iso = (now + timedelta(minutes=CLAIM_LEASE_MINUTES)).isoformat()
    due = list_due(now_iso)
    claimed = [feed_id for feed_id, seen in due if claim(feed_id, seen, lease_iso)]
    enqueued = enqueue(claimed, now_iso)
    emit_metrics(len(due), len(claimed), enqueued)
    print(f'[rss-schedule] due {len(due)}, claimed {len(claimed)}, enqueued {enqueued}')
    return {'statusCode': 200,
            'body': json.dumps({'due': len(due), 'claimed': len(claimed),
                                'enqueued': enqueued})}


def list_due(now_iso):
    '''(feed_id, next_fetch_at) for every active feed due at or before now.'''
    due = []
    kwargs = {
        'IndexName': 'by_due',
        'KeyConditionExpression': Key('due_shard').eq('active') & Key('next_fetch_at').lte(now_iso),
        'ProjectionExpression': 'feed_id, next_fetch_at',
    }
    while len(due) < MAX_FEEDS_PER_TICK:
        response = table.query(**kwargs)
        due.extend((row['feed_id'], row['next_fetch_at']) for row in response.get('Items', []))
        if 'LastEvaluatedKey' not in response:
            break
        kwargs['ExclusiveStartKey'] = response['LastEvaluatedKey']
    return due[:MAX_FEEDS_PER_TICK]


def claim(feed_id, seen_next_fetch_at, lease_iso):
    '''Advances next_fetch_at to the lease; False if another tick got there
    first (the row's next_fetch_at no longer matches what the query saw).'''
    try:
        table.update_item(
            Key={'feed_id': feed_id},
            UpdateExpression='SET next_fetch_at = :lease',
            ConditionExpression='next_fetch_at = :seen AND attribute_exists(due_shard)',
            ExpressionAttributeValues={':lease': lease_iso, ':seen': seen_next_fetch_at},
        )
    except ClientError as err:
        if err.response['Error']['Code'] == 'ConditionalCheckFailedException':
            return False
        raise
    return True


def enqueue(feed_ids, claimed_at):
    '''Sends one message per feed in batches of ten; returns the count sent.'''
    sent = 0
    for start in range(0, len(feed_ids), 10):
        batch = feed_ids[start:start + 10]
        response = sqs.send_message_batch(
            QueueUrl=QUEUE_URL,
            Entries=[{'Id': str(i),
                      'MessageBody': json.dumps({'feed_id': fid, 'claimed_at': claimed_at})}
                     for i, fid in enumerate(batch)])
        sent += len(response.get('Successful', []))
        for failure in response.get('Failed', []):
            # The claim stands, so the feed comes due again when the lease
            # lapses; nothing to undo.
            print(f'[rss-schedule] enqueue failed for {batch[int(failure["Id"])]}: '
                  f'{failure.get("Code")} {failure.get("Message")}')
    return sent


def emit_metrics(due, claimed, enqueued):
    '''CloudWatch EMF line: free metrics, no API call (as push_dispatch).'''
    print(json.dumps({
        '_aws': {
            'Timestamp': int(time.time() * 1000),
            'CloudWatchMetrics': [{
                'Namespace': 'Cabal/Rss',
                'Dimensions': [[]],
                'Metrics': [
                    {'Name': 'FeedsDue', 'Unit': 'Count'},
                    {'Name': 'FeedsClaimed', 'Unit': 'Count'},
                    {'Name': 'FeedsEnqueued', 'Unit': 'Count'},
                ],
            }],
        },
        'FeedsDue': due,
        'FeedsClaimed': claimed,
        'FeedsEnqueued': enqueued,
    }))
