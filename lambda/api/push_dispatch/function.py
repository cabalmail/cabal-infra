'''SQS consumer that fans a new-mail wake signal out to APNs and FCM.

The imap container's procmail recipe enqueues {user, folder, uid, msg_id} per
local delivery (docker/shared/push-enqueue.sh); this consumer looks up the
recipient's registered device tokens in cabal-push-tokens and routes each row
to its platform's sender: Apple rows (ios/macos) to APNs, android rows to
FCM. Payloads deliberately carry no sender/subject/body — the device fetches
enrichment from /push_envelope with the user's own JWT, so neither Apple's
nor Google's infrastructure ever sees message content (see
docs/0.11.x/push-notifications.md and docs/1.x/android-push-notifications.md).

Failure posture:
  * A sender not configured (placeholder SSM values under /cabal/apns or
    /cabal/fcm): skip that platform's rows cleanly. The check is per sender —
    an Android-only environment must not DLQ Apple rows or vice versa, and an
    environment with neither app must not accumulate a DLQ backlog.
  * Token-level rejection (APNs 410/BadDeviceToken, FCM UNREGISTERED and
    kin): delete the token row; the device is gone or the token rotated.
  * Transport/auth/5xx errors: raise only when nothing was delivered, so SQS
    redelivers without double-notifying devices that already got the alert
    (apns-collapse-id and the Android app's identity-keyed notification ids
    additionally dedup the display on redelivery).

The event source mapping uses batch_size 1 so a single failing signal retries
on its own rather than dragging a whole batch with it.'''
import hashlib
import json
import os
import time

import boto3  # pylint: disable=import-error
from boto3.dynamodb.conditions import Key  # pylint: disable=import-error

from apns import ApnsClient, ApnsError, ApnsTransportError  # pylint: disable=import-error
from fcm import FcmClient, FcmError, FcmTransportError  # pylint: disable=import-error

ddb = boto3.resource('dynamodb')
TABLE_NAME = os.environ.get('PUSH_TOKENS_TABLE_NAME', 'cabal-push-tokens')
table = ddb.Table(TABLE_NAME)
ssm = boto3.client('ssm')

# Sentinel prefix Terraform seeds /cabal/apns/* and /cabal/fcm/* with
# (modules/app/push_dispatch.tf); a value still carrying it means "not
# configured".
PLACEHOLDER_PREFIX = 'placeholder-'

# How long a warm container trusts a "not configured" verdict before
# re-reading SSM. Without the recheck, a container that went warm before the
# operator provisioned a credential would ack-and-drop signals until Lambda
# happened to recycle it — hours, under steady mail flow.
NOT_CONFIGURED_TTL_SECONDS = 300

# Skip the per-send last_seen_at write when the row was refreshed this
# recently; the attribute exists to GC dead tokens, not to timestamp pushes.
LAST_SEEN_REFRESH_SECONDS = 12 * 3600

# Bundle ids that receive silent (content-available) pushes instead of
# alerts; see _payload's docstring for the macOS rationale.
SILENT_BUNDLE_IDS = frozenset({'com.cabalmail.CabalmailMac'})

# Warm-container caches: sender config/connections survive across
# invocations, which is what makes provider-token reuse worthwhile.
_APNS_CLIENT = None
_APNS_RECHECK_AT = 0.0
_FCM_CLIENT = None
_FCM_RECHECK_AT = 0.0


def _ssm_config(path):
    '''Reads one credential namespace into a {leaf_name: value} dict.'''
    response = ssm.get_parameters_by_path(Path=path, WithDecryption=True)
    return {
        param['Name'].rsplit('/', 1)[-1]: param['Value']
        for param in response['Parameters']
    }


def _configured(config, required):
    '''False while any required leaf is absent or still the Terraform seed.'''
    return not any(
        config.get(name, PLACEHOLDER_PREFIX).startswith(PLACEHOLDER_PREFIX)
        for name in required)


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
    config = _ssm_config('/cabal/apns')
    if not _configured(config, ('team_id', 'key_id', 'private_key', 'endpoint')):
        print('[push-dispatch] APNs credentials not provisioned; '
              'Apple wake signals will be dropped')
        _APNS_RECHECK_AT = time.monotonic() + NOT_CONFIGURED_TTL_SECONDS
        return None
    _APNS_CLIENT = ApnsClient(
        config['endpoint'], config['team_id'], config['key_id'],
        config['private_key'],
    )
    return _APNS_CLIENT


def _fcm_client():
    '''Same contract as _apns_client, for the FCM sender. A present-but-
    unusable service account (bad JSON, missing fields, non-RSA key) is
    logged and treated as not configured rather than raised: a bad
    credential must not turn every wake signal into a DLQ entry, and the
    TTL recheck picks up a corrected re-seed without a deploy.'''
    global _FCM_CLIENT, _FCM_RECHECK_AT  # pylint: disable=global-statement
    if _FCM_CLIENT is not None:
        return _FCM_CLIENT
    if time.monotonic() < _FCM_RECHECK_AT:
        return None
    config = _ssm_config('/cabal/fcm')
    if not _configured(config, ('service_account',)):
        print('[push-dispatch] FCM credentials not provisioned; '
              'Android wake signals will be dropped')
        _FCM_RECHECK_AT = time.monotonic() + NOT_CONFIGURED_TTL_SECONDS
        return None
    try:
        _FCM_CLIENT = FcmClient(config['service_account'])
    except ValueError as err:
        print(f'[push-dispatch] FCM service account unusable, treating as '
              f'not provisioned: {err}')
        _FCM_RECHECK_AT = time.monotonic() + NOT_CONFIGURED_TTL_SECONDS
        return None
    return _FCM_CLIENT


def _client_for(platform):
    '''Maps a token row's platform onto its sender (or None: unconfigured).'''
    if platform == 'android':
        return _fcm_client()
    return _apns_client()


def _wants_folder(row, folder):
    '''Applies the per-token folder opt-in: no enabled_folders attribute means
    INBOX only, "*" means everything, otherwise exact membership.'''
    enabled = row.get('enabled_folders') or {'INBOX'}
    return '*' in enabled or folder in enabled


def _emit_metrics(sent, failed, latency_ms, per_platform):
    '''CloudWatch EMF lines per invocation: free metrics, no API calls. The
    undimensioned totals keep the pre-FCM series intact; one extra line per
    platform touched makes a single-sender failure mode visible on its own.'''
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
    for platform, counts in sorted(per_platform.items()):
        print(json.dumps({
            '_aws': {
                'Timestamp': int(time.time() * 1000),
                'CloudWatchMetrics': [{
                    'Namespace': 'Cabal/Push',
                    'Dimensions': [['Platform']],
                    'Metrics': [
                        {'Name': 'Sent', 'Unit': 'Count'},
                        {'Name': 'Failed', 'Unit': 'Count'},
                    ],
                }],
            },
            'Platform': platform,
            'Sent': counts['sent'],
            'Failed': counts['failed'],
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


def _payload(signal, silent):
    '''Builds the content-free APNs payload and its collapse id.

    `silent` selects a background (content-available) push with no alert:
    macOS's notification daemon kills service extensions before they run
    ("sluggish startup", an unresolved platform defect) AND only consults
    willPresent while the app is frontmost, so an alert push to a Mac could
    never be enriched. The Mac app instead receives this silent wake while
    running (any focus state) and posts its own enriched local notification;
    a quit Mac app gets nothing, a trade the maintainer chose over a
    permanently generic banner. iOS keeps the alert form — its extension
    works.'''
    folder = signal['folder']
    uid = int(signal.get('uid') or 0)
    msg_id = signal.get('msg_id') or ''
    ref = {'folder': folder, 'uid': uid, 'msg_id': msg_id}
    if silent:
        payload = {'aps': {'content-available': 1}, 'msgRef': ref}
    else:
        payload = {
            'aps': {
                'alert': 'New mail',
                'mutable-content': 1,
                'category': 'MAIL_MESSAGE',
                'sound': 'default',
            },
            'msgRef': ref,
        }
    # Collapse on message identity so a redelivered signal replaces, rather
    # than stacks on, the notification it already produced. The UID hint can
    # be 0 (procmail runs before Dovecot assigns one), so fold msg_id in —
    # hashed, because APNs caps apns-collapse-id at 64 bytes and truncating a
    # raw Message-ID would collapse distinct messages that share a long
    # provider prefix (Exchange ids differ only near the end).
    msg_digest = hashlib.sha256(msg_id.encode()).hexdigest()[:16] if msg_id else ''
    return payload, f'{folder}:{uid}:{msg_digest}'[:64]


def _fcm_data(signal):
    '''The FCM data map, mirroring the APNs msgRef. Every value must be a
    string — FCM rejects non-string data values.'''
    return {
        'folder': signal['folder'],
        'uid': str(int(signal.get('uid') or 0)),
        'msg_id': signal.get('msg_id') or '',
    }


def _send_row(client, row, signal, apns_payloads, collapse_id):
    '''Routes one token row to its platform's sender.

    No FCM collapse id: collapse_key only collapses messages queued while the
    device is offline and FCM keeps at most four keys per device, so
    per-message keys would silently drop older queued signals. Redelivery
    dedup on Android is enforced where the app already controls display —
    notification ids keyed on the message identity.'''
    if row.get('platform') == 'android':
        client.send(row['device_token'], _fcm_data(signal))
    else:
        silent = row['bundle_id'] in SILENT_BUNDLE_IDS
        client.send(row['device_token'], row['bundle_id'],
                    apns_payloads[silent], collapse_id, background=silent)


def _dispatch(signal):  # pylint: disable=too-many-locals
    '''Sends one wake signal to every opted-in token whose sender is
    configured.

    Returns (sent, failed, retryable, per_platform): `failed` counts every
    non-delivery, `retryable` only the subset a redelivery could plausibly
    fix, `per_platform` the sent/failed split per token-row platform. Rows
    whose platform's sender is unconfigured are skipped without counting —
    that is this environment's steady state, not a failure.'''
    user = signal['user']
    folder = signal['folder']
    rows = table.query(KeyConditionExpression=Key('user').eq(user))['Items']
    apns_payloads = {silent: _payload(signal, silent)[0] for silent in (False, True)}
    collapse_id = _payload(signal, silent=False)[1]

    sent, failed, retryable = 0, 0, 0
    per_platform = {}
    now = time.strftime('%Y-%m-%dT%H:%M:%S+00:00', time.gmtime())
    for row in rows:
        if not _wants_folder(row, folder):
            continue
        # Rows always carry platform (push_register sets it from the bundle
        # id); the fallback only guards hand-inserted rows.
        platform = row.get('platform') or 'ios'
        client = _client_for(platform)
        if client is None:
            continue
        counts = per_platform.setdefault(platform, {'sent': 0, 'failed': 0})
        device_token = row['device_token']
        try:
            _send_row(client, row, signal, apns_payloads, collapse_id)
        except (ApnsError, FcmError) as err:
            failed += 1
            counts['failed'] += 1
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
        except (ApnsTransportError, FcmTransportError) as err:
            # Caught per token, not per signal: a transport failure on one
            # send must not abort the loop and strand the remaining devices
            # (the handler docstring's "raises only when nothing delivered"
            # depends on this).
            failed += 1
            counts['failed'] += 1
            retryable += 1
            print(f'[push-dispatch] transport failure for {user}: {err}')
            continue
        sent += 1
        counts['sent'] += 1
        # Freshness bookkeeping only; skip the write when the row is already
        # recent so a busy mailbox doesn't pay one UpdateItem per device per
        # delivered message.
        if _is_stale(row.get('last_seen_at'), now):
            _mark(user, device_token, 'last_seen_at', now)
    return sent, failed, retryable, per_platform


def handler(event, _context):
    '''Processes one queue record (batch_size = 1). Raises only when the
    signal produced no deliveries but should have, so SQS redelivers.'''
    for record in event.get('Records', []):
        signal = json.loads(record['body'])
        if not signal.get('user') or not signal.get('folder'):
            print(f'[push-dispatch] malformed signal dropped: {record["body"][:200]}')
            continue
        received_ms = int(record.get('attributes', {}).get('SentTimestamp', 0))
        sent, failed, retryable, per_platform = _dispatch(signal)
        latency_ms = int(time.time() * 1000) - received_ms if received_ms else 0
        _emit_metrics(sent, failed, latency_ms, per_platform)
        if retryable and not sent:
            raise RuntimeError(
                f'no deliveries for {signal["user"]}/{signal["folder"]}: '
                f'{failed} failed')
    return {'statusCode': 200}
