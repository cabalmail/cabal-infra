'''Weekly garbage collection for stale APNs device-token rows.

push_dispatch prunes tokens the moment APNs rejects them (410 Unregistered /
BadDeviceToken), and push_deregister removes them on sign-out — so this is
the backstop for the rows neither path can reach: a device that stopped
launching the app (no re-registration refreshing last_seen_at) whose user
receives no mail (no send ever surfaces an APNs rejection). Without mail
there is no push, so nothing is lost by reaping; a device that comes back
re-registers on its next launch. See docs/0.11.0/push-notifications.md.

Scheduled weekly via EventBridge Scheduler
(terraform/infra/modules/app/push_token_gc.tf).'''
import datetime
import os

import boto3  # pylint: disable=import-error

ddb = boto3.resource('dynamodb')
TABLE_NAME = os.environ.get('PUSH_TOKENS_TABLE_NAME', 'cabal-push-tokens')
table = ddb.Table(TABLE_NAME)

MAX_IDLE_DAYS = 90


def _is_stale(row, cutoff):
    '''True when the row's freshest timestamp is older than the cutoff.
    Registration always stamps both fields, so a row with neither is
    malformed and reaped too.'''
    freshest = max(
        str(row.get('last_seen_at') or ''),
        str(row.get('created_at') or ''),
    )
    return freshest < cutoff


def handler(_event, _context):
    '''Scans the token table and deletes rows idle past MAX_IDLE_DAYS.'''
    cutoff = (
        datetime.datetime.now(datetime.timezone.utc)
        - datetime.timedelta(days=MAX_IDLE_DAYS)
    ).isoformat()

    scanned, reaped = 0, 0
    scan_kwargs = {
        'ProjectionExpression': '#u, device_token, last_seen_at, created_at',
        'ExpressionAttributeNames': {'#u': 'user'},
    }
    while True:
        page = table.scan(**scan_kwargs)
        for row in page.get('Items', []):
            scanned += 1
            if _is_stale(row, cutoff):
                table.delete_item(
                    Key={'user': row['user'], 'device_token': row['device_token']})
                reaped += 1
                print(f"[push-token-gc] reaped token for {row['user']} "
                      f"(last seen {row.get('last_seen_at') or 'never'})")
        if 'LastEvaluatedKey' not in page:
            break
        scan_kwargs['ExclusiveStartKey'] = page['LastEvaluatedKey']

    print(f'[push-token-gc] scanned {scanned}, reaped {reaped}')
    return {'statusCode': 200, 'body': f'{{"scanned": {scanned}, "reaped": {reaped}}}'}
