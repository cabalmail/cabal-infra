'''Registers (upserts) an APNs device token for the calling user.

The Apple clients call this on every launch after sign-in and again whenever
APNs rotates the token, so the write must be an idempotent upsert. One row per
(user, device token); push_dispatch fans a wake signal out to every row it
finds for the recipient. See docs/0.11.0/push-notifications.md.
'''
import datetime
import json
import os
import re
import boto3  # pylint: disable=import-error

ddb = boto3.resource('dynamodb')
TABLE_NAME = os.environ.get('PUSH_TOKENS_TABLE_NAME', 'cabal-push-tokens')
table = ddb.Table(TABLE_NAME)

# APNs device tokens are opaque hex; currently 32 bytes (64 hex chars) but
# Apple documents the length as subject to change, so bound rather than pin.
DEVICE_TOKEN_RE = re.compile(r'^[0-9a-f]{16,400}$')

# bundle_id doubles as the APNs topic in push_dispatch, so only known app ids
# are accepted; platform is informational and derived rather than trusted.
ALLOWED_BUNDLE_IDS = {
    'com.cabalmail.Cabalmail': 'ios',
    'com.cabalmail.CabalmailMac': 'macos',
}

MAX_ENABLED_FOLDERS = 100
FOLDER_RE = re.compile(r'^[A-Za-z0-9 _\-./]{1,255}$')

MAX_INFO_LENGTH = 64


def _validate_enabled_folders(value):
    '''Returns a cleaned list of folder names (or ["*"]), or raises ValueError.

    Absent/empty means "INBOX only" and is stored as no attribute at all
    (DynamoDB string sets cannot be empty).
    '''
    if not isinstance(value, list) or len(value) > MAX_ENABLED_FOLDERS:
        raise ValueError('enabled_folders must be a list of folder names')
    cleaned = []
    for folder in value:
        if folder == '*':
            return ['*']
        if not isinstance(folder, str) or not FOLDER_RE.match(folder):
            raise ValueError(f'invalid folder name: {folder!r}')
        cleaned.append(folder.replace('/', '.'))
    return cleaned


def _info_field(body, key):
    '''Returns a short informational string field, clipped, never trusted.'''
    value = body.get(key, '')
    if not isinstance(value, str):
        return ''
    return value[:MAX_INFO_LENGTH]


def handler(event, _context):
    '''Upserts the caller's device-token row.'''
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    try:
        body = json.loads(event.get('body') or '{}')
    except (TypeError, ValueError):
        return {'statusCode': 400, 'body': json.dumps({'Error': 'Invalid JSON body.'})}

    device_token = str(body.get('device_token', '')).lower()
    if not DEVICE_TOKEN_RE.match(device_token):
        return {'statusCode': 400, 'body': json.dumps({'Error': 'Invalid device_token.'})}

    bundle_id = body.get('bundle_id')
    if bundle_id not in ALLOWED_BUNDLE_IDS:
        return {'statusCode': 400, 'body': json.dumps({'Error': 'Unknown bundle_id.'})}

    try:
        enabled_folders = _validate_enabled_folders(body['enabled_folders']) \
            if body.get('enabled_folders') else []
    except ValueError as err:
        return {'statusCode': 400, 'body': json.dumps({'Error': str(err)})}

    now = datetime.datetime.now(datetime.timezone.utc).isoformat()
    # Merge-style upsert: created_at survives re-registration, last_seen_at
    # tracks it, and a previous last_failure is cleared by the fresh proof of
    # life. enabled_folders is REMOVEd when the client sends none, so a reset
    # back to the inbox-only default actually lands. Every attribute name is
    # #-aliased: several of them collide with DynamoDB reserved words.
    sets = [
        '#b = :b', '#p = :p', '#v = :v', '#l = :l',
        '#c = if_not_exists(#c, :now)', '#s = :now',
    ]
    names = {
        '#b': 'bundle_id', '#p': 'platform', '#v': 'app_version',
        '#l': 'locale', '#c': 'created_at', '#s': 'last_seen_at',
        '#lf': 'last_failure', '#ef': 'enabled_folders',
    }
    values = {
        ':b': bundle_id,
        ':p': ALLOWED_BUNDLE_IDS[bundle_id],
        ':v': _info_field(body, 'app_version'),
        ':l': _info_field(body, 'locale'),
        ':now': now,
    }
    removes = ['#lf']
    if enabled_folders:
        sets.append('#ef = :f')
        values[':f'] = set(enabled_folders)
    else:
        removes.append('#ef')

    try:
        table.update_item(
            Key={'user': user, 'device_token': device_token},
            UpdateExpression=f"SET {', '.join(sets)} REMOVE {', '.join(removes)}",
            ExpressionAttributeNames=names,
            ExpressionAttributeValues=values,
        )
    except Exception as err:  # pylint: disable=broad-exception-caught
        return {'statusCode': 500, 'body': json.dumps({'Error': str(err)})}
    return {'statusCode': 200, 'body': json.dumps({'status': 'registered'})}
