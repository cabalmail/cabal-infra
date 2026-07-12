'''SQS consumer that fans a new-mail wake signal out to APNs.

The imap container's procmail recipe enqueues {user, folder, uid, msg_id} per
local delivery (docker/shared/push-enqueue.sh); this consumer looks up the
user's registered device tokens in cabal-push-tokens and sends one
content-free APNs alert per opted-in token. The payload deliberately carries
no sender/subject/body — the device's Notification Service Extension calls
/push_envelope to enrich the alert locally, so Apple's infrastructure never
sees message content (docs/0.11.0/push-notifications.md).

Failure posture:
  * APNs not configured (placeholder SSM values): drop the signal cleanly.
    Environments without an Apple app must not accumulate a DLQ backlog.
  * Token-level rejection (410 Unregistered / BadDeviceToken): delete the
    token row; the device is gone or the token rotated.
  * Transport/auth/5xx errors: raise only when nothing was delivered, so SQS
    redelivers without double-notifying devices that already got the alert
    (apns-collapse-id additionally dedups the display on redelivery).

The event source mapping uses batch_size 1 so a single failing signal retries
on its own rather than dragging a whole batch with it.'''
import hashlib
import json
import os
import time

import boto3  # pylint: disable=import-error
from boto3.dynamodb.conditions import Key  # pylint: disable=import-error

from apns import ApnsClient, ApnsError, ApnsTransportError  # pylint: disable=import-error

ddb = boto3.resource('dynamodb')
TABLE_NAME = os.environ.get('PUSH_TOKENS_TABLE_NAME', 'cabal-push-tokens')
table = ddb.Table(TABLE_NAME)
ssm = boto3.client('ssm')

# Sentinel prefix Terraform seeds /cabal/apns/* with (modules/app/
# push_dispatch.tf); a value still carrying it means "not configured".
PLACEHOLDER_PREFIX = 'placeholder-'

# How long a warm container trusts a "not configured" verdict before
# re-reading SSM. Without the recheck, a container that went warm before the
# operator provisioned the APNs key would ack-and-drop signals until Lambda
# happened to recycle it — hours, under steady mail flow.
NOT_CONFIGURED_TTL_SECONDS = 300

# Skip the per-send last_seen_at write when the row was refreshed this
# recently; the attribute exists to GC dead tokens, not to timestamp pushes.
LAST_SEEN_REFRESH_SECONDS = 12 * 3600

# Warm-container caches: the APNs config/connection survive across
# invocations, which is what makes provider-token reuse worthwhile.
_APNS_CLIENT = None
_APNS_RECHECK_AT = 0.0


def _apns_client():
    '''Returns the shared ApnsClient, or None when APNs is not configured.
    A configured client is cached for the container's life; the unconfigured
    verdict is re-checked after NOT_CONFIGURED_TTL_SECONDS so provisioning
    the SSM parameters takes effect without waiting out warm containers.'''
    global _APNS_CLIENT, _APNS_RECHECK_AT  # pylint: disable=global-statement
    if _APNS_CLIENT is not None:
        return _APNS_CLIENT
    if time.monotonic() < _APNS_RECHECK_AT:
        return None
    response = ssm.get_parameters_by_path(
        Path='/cabal/apns', WithDecryption=True)
    config = {
        param['Name'].rsplit('/', 1)[-1]: param['Value']
        for param in response['Parameters']
    }
    required = ('team_id', 'key_id', 'private_key', 'endpoint')
    if any(config.get(name, PLACEHOLDER_PREFIX).startswith(PLACEHOLDER_PREFIX)
           for name in required):
        print('[push-dispatch] APNs credentials not provisioned; '
              'wake signals will be dropped')
        _APNS_RECHECK_AT = time.monotonic() + NOT_CONFIGURED_TTL_SECONDS
        return None
    _APNS_CLIENT = ApnsClient(
        config['endpoint'], config['team_id'], config['key_id'],
        config['private_key'],
    )
    return _APNS_CLIENT


def _wants_folder(row, folder):
    '''Applies the per-token folder opt-in: no enabled_folders attribute means
    INBOX only, "*" means everything, otherwise exact membership.'''
    enabled = row.get('enabled_folders') or {'INBOX'}
    return '*' in enabled or folder in enabled


def _emit_metrics(sent, failed, latency_ms):
    '''One CloudWatch EMF line per invocation: free metrics, no API calls.'''
    print(json.dumps({
        '_aws': {
            'Timestamp': int(time.time() * 1000),
            'CloudWatchMetrics': [{
                'Namespace': 'Cabal/Push',
                'Dimensions': [[]],
                'Metrics': [
                    {'Name': 'Sent', 'Unit': 'Count'},
                    {'Name': 'Failed', 'Unit': 'Count'},
                    {'Name': 'LatencyMs', 'Unit': 'Milliseconds'},
                ],
            }],
        },
        'Sent': sent,
        'Failed': failed,
        'LatencyMs': latency_ms,
    }))


def _is_stale(last_seen_at, now):
    '''True when the ISO-8601 last_seen_at is absent, unparseable, or older
    than LAST_SEEN_REFRESH_SECONDS relative to `now` (same format).'''
    if not last_seen_at:
        return True
    try:
        then = time.mktime(time.strptime(str(last_seen_at)[:19], '%Y-%m-%dT%H:%M:%S'))
        current = time.mktime(time.strptime(now[:19], '%Y-%m-%dT%H:%M:%S'))
    except ValueError:
        return True
    return current - then > LAST_SEEN_REFRESH_SECONDS


def _mark(user, device_token, attribute, value):
    '''Best-effort bookkeeping write on a token row; never fails a dispatch.'''
    try:
        table.update_item(
            Key={'user': user, 'device_token': device_token},
            UpdateExpression='SET #a = :v',
            ExpressionAttributeNames={'#a': attribute},
            ExpressionAttributeValues={':v': value},
        )
    except Exception as err:  # pylint: disable=broad-exception-caught
        print(f'[push-dispatch] bookkeeping write failed: {err}')


def _payload(signal):
    '''Builds the content-free APNs payload and its collapse id.'''
    folder = signal['folder']
    uid = int(signal.get('uid') or 0)
    msg_id = signal.get('msg_id') or ''
    payload = {
        'aps': {
            'alert': 'New mail',
            'mutable-content': 1,
            'category': 'MAIL_MESSAGE',
            'sound': 'default',
        },
        'msgRef': {'folder': folder, 'uid': uid, 'msg_id': msg_id},
    }
    # Collapse on message identity so a redelivered signal replaces, rather
    # than stacks on, the notification it already produced. The UID hint can
    # be 0 (procmail runs before Dovecot assigns one), so fold msg_id in —
    # hashed, because APNs caps apns-collapse-id at 64 bytes and truncating a
    # raw Message-ID would collapse distinct messages that share a long
    # provider prefix (Exchange ids differ only near the end).
    msg_digest = hashlib.sha256(msg_id.encode()).hexdigest()[:16] if msg_id else ''
    return payload, f'{folder}:{uid}:{msg_digest}'[:64]


def _dispatch(client, signal):
    '''Sends one wake signal to every opted-in token.

    Returns (sent, failed, retryable): `failed` counts every non-delivery,
    `retryable` only the subset a redelivery could plausibly fix. Transport
    errors (APNs unreachable) propagate to the caller so the whole record
    retries.'''
    user = signal['user']
    folder = signal['folder']
    rows = table.query(KeyConditionExpression=Key('user').eq(user))['Items']
    payload, collapse_id = _payload(signal)

    sent, failed, retryable = 0, 0, 0
    now = time.strftime('%Y-%m-%dT%H:%M:%S+00:00', time.gmtime())
    for row in rows:
        if not _wants_folder(row, folder):
            continue
        device_token = row['device_token']
        try:
            client.send(device_token, row['bundle_id'], payload, collapse_id)
        except ApnsError as err:
            failed += 1
            if err.permanent:
                # A pruned token is resolved, not retryable: redelivering the
                # signal would find the row already gone.
                print(f'[push-dispatch] pruning token for {user}: {err}')
                table.delete_item(
                    Key={'user': user, 'device_token': device_token})
            else:
                retryable += 1
                print(f'[push-dispatch] send failed for {user}: {err}')
                _mark(user, device_token, 'last_failure', err.reason or str(err.status))
            continue
        except ApnsTransportError as err:
            # Caught per token, not per signal: a transport failure on one
            # send must not abort the loop and strand the remaining devices
            # (the handler docstring's "raises only when nothing delivered"
            # depends on this).
            failed += 1
            retryable += 1
            print(f'[push-dispatch] transport failure for {user}: {err}')
            continue
        sent += 1
        # Freshness bookkeeping only; skip the write when the row is already
        # recent so a busy mailbox doesn't pay one UpdateItem per device per
        # delivered message.
        if _is_stale(row.get('last_seen_at'), now):
            _mark(user, device_token, 'last_seen_at', now)
    return sent, failed, retryable


def handler(event, _context):
    '''Processes one queue record (batch_size = 1). Raises only when the
    signal produced no deliveries but should have, so SQS redelivers.'''
    client = _apns_client()
    for record in event.get('Records', []):
        signal = json.loads(record['body'])
        if not signal.get('user') or not signal.get('folder'):
            print(f'[push-dispatch] malformed signal dropped: {record["body"][:200]}')
            continue
        if client is None:
            continue
        received_ms = int(record.get('attributes', {}).get('SentTimestamp', 0))
        sent, failed, retryable = _dispatch(client, signal)
        latency_ms = int(time.time() * 1000) - received_ms if received_ms else 0
        _emit_metrics(sent, failed, latency_ms)
        if retryable and not sent:
            raise RuntimeError(
                f'no deliveries for {signal["user"]}/{signal["folder"]}: '
                f'{failed} failed')
    return {'statusCode': 200}
