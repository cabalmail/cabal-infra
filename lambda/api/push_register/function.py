'''Registers (upserts) a push device token for the calling user.

The clients call this on every launch after sign-in and again whenever the
push service rotates the token, so the write must be an idempotent upsert.
One row per (user, device token); push_dispatch fans a wake signal out to
every row it finds for the recipient, routing Apple rows to APNs and android
rows to FCM. See docs/0.11.x/push-notifications.md and
docs/1.x/android-push-notifications.md.
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
# Registration normalizes them to lowercase.
APNS_DEVICE_TOKEN_RE = re.compile(r'^[0-9a-f]{16,400}$')

# FCM registration tokens are opaque strings (~140-200 chars today: an
# instance id, a colon, and a base64url-ish payload) with no documented
# grammar, so bound charset and length rather than pin. Case-significant —
# never lowercase one.
FCM_DEVICE_TOKEN_RE = re.compile(r'^[A-Za-z0-9_:\-]{16,400}$')

# bundle_id selects the sender in push_dispatch (and doubles as the APNs
# topic for Apple rows), so only known app ids are accepted; platform is
# informational and derived rather than trusted.
ALLOWED_BUNDLE_IDS = {
    'com.cabalmail.Cabalmail': 'ios',
    'com.cabalmail.CabalmailMac': 'macos',
    'com.cabalmail.android': 'android',
}

MAX_ENABLED_FOLDERS = 100
# Mirrors helper.validate_folder_name's grammar (charset, 255-byte cap,
# no ''/'.'/'..' segments) without importing helper: these names are only
# ever compared against push_dispatch's folder strings, and helper's import
# would drag imapclient plus an SSM read into this otherwise-tiny zip.
FOLDER_RE = re.compile(r'^[A-Za-z0-9 _\-./]+$')

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
        if not isinstance(folder, str) or not FOLDER_RE.match(folder) \
                or len(folder.encode('utf-8')) > 255 \
                or any(seg in ('', '.', '..') for seg in folder.split('/')):
            raise ValueError(f'invalid folder name: {folder!r}')
        cleaned.append(folder.replace('/', '.'))
    return cleaned


def _validate_device_token(bundle_id, raw):
    '''Returns (normalized_token, None) on success or (None, error_response)
    per the platform's token grammar: Android tokens are case-significant
    and pass through as-is; Apple tokens are hex and normalize to
    lowercase.'''
    token = str(raw or '')
    if ALLOWED_BUNDLE_IDS[bundle_id] == 'android':
        if FCM_DEVICE_TOKEN_RE.match(token):
            return token, None
    else:
        token = token.lower()
        if APNS_DEVICE_TOKEN_RE.match(token):
            return token, None
    return None, {'statusCode': 400, 'body': json.dumps({'Error': 'Invalid device_token.'})}


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

    # Bundle id first: it decides which token grammar applies.
    bundle_id = body.get('bundle_id')
    if bundle_id not in ALLOWED_BUNDLE_IDS:
        return {'statusCode': 400, 'body': json.dumps({'Error': 'Unknown bundle_id.'})}

    device_token, error = _validate_device_token(bundle_id, body.get('device_token'))
    if error:
        return error

    # Tri-state, matching set_preferences' merge semantics: key absent =
    # leave the row's existing selection alone (the app re-registers on
    # every launch and must not wipe preferences it isn't sending); key
    # present but empty = explicit reset to the inbox-only default; key
    # present with folders = replace.
    enabled_folders = None
    if 'enabled_folders' in body:
        try:
            enabled_folders = _validate_enabled_folders(body['enabled_folders'] or [])
        except ValueError as err:
            return {'statusCode': 400, 'body': json.dumps({'Error': str(err)})}

    now = datetime.datetime.now(datetime.timezone.utc).isoformat()
    # Merge-style upsert: created_at survives re-registration, last_seen_at
    # tracks it, and a previous last_failure is cleared by the fresh proof of
    # life. Every attribute name is #-aliased: several of them collide with
    # DynamoDB reserved words.
    sets = [
        '#b = :b', '#p = :p', '#v = :v', '#l = :l',
        '#c = if_not_exists(#c, :now)', '#s = :now',
    ]
    names = {
        '#b': 'bundle_id', '#p': 'platform', '#v': 'app_version',
        '#l': 'locale', '#c': 'created_at', '#s': 'last_seen_at',
        '#lf': 'last_failure',
    }
    values = {
        ':b': bundle_id,
        ':p': ALLOWED_BUNDLE_IDS[bundle_id],
        ':v': _info_field(body, 'app_version'),
        ':l': _info_field(body, 'locale'),
        ':now': now,
    }
    removes = ['#lf']
    # '#ef' joins names only when an expression uses it: DynamoDB rejects the
    # whole update ("Value provided in ExpressionAttributeNames unused") if an
    # alias appears without a reference, which is the common key-absent case.
    if enabled_folders:
        names['#ef'] = 'enabled_folders'
        sets.append('#ef = :f')
        values[':f'] = set(enabled_folders)
    elif enabled_folders is not None:
        # Explicit empty list: reset to the inbox-only default (DynamoDB
        # string sets cannot be empty, so "default" is attribute absence).
        names['#ef'] = 'enabled_folders'
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
