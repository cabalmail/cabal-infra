'''Persists the current user's preferences (theme/accent/density/name/app).'''
import json
import os
import boto3  # pylint: disable=import-error

ddb = boto3.resource('dynamodb')
TABLE_NAME = os.environ.get('USER_PREFERENCES_TABLE_NAME', 'cabal-user-preferences')
table = ddb.Table(TABLE_NAME)

ALLOWED = {
    'theme':   {'light', 'dark'},
    'accent':  {'ink', 'oxblood', 'forest', 'azure', 'amber', 'plum'},
    'density': {'compact', 'normal', 'roomy'},
}

# Free-text display name used by the /send Lambda as the From header's
# display name. Control characters are rejected outright (a stored CR/LF
# would otherwise be a header-injection vector at send time) and the
# length is capped to keep the composed From header sane. Empty string
# means "no display name".
MAX_NAME_LENGTH = 100

# Apple-client preferences, namespaced under `app` so they never collide with
# the flat theme/accent/density fields the React app owns. The enum-valued keys
# mirror the Swift `Preferences` enums exactly (see
# apple/CabalmailKit/Sources/CabalmailKit/Settings/Preferences.swift); the two
# free-text keys reuse the display-name/signature validators below.
APP_ALLOWED = {
    'mark_as_read':             {'manual', 'on_open', 'after_delay'},
    'load_remote_content':      {'off', 'ask', 'always'},
    'dispose_action':           {'archive', 'trash'},
    'theme':                    {'system', 'light', 'dark'},
    'default_body_render_mode': {'original', 'reader'},
    'folder_count_display':     {'unread', 'total', 'both'},
    'crash_reporting_enabled':  {'0', '1'},
}

# The signature lands in the outgoing message body (not a header), so newlines
# and tabs are legitimate; only other control characters are rejected. Capped
# so a runaway value can't bloat every row.
MAX_SIGNATURE_LENGTH = 2000


def _validate_name(value):
    '''Returns the trimmed display name, or None if the value is invalid.'''
    if not isinstance(value, str):
        return None
    cleaned = value.strip()
    if len(cleaned) > MAX_NAME_LENGTH:
        return None
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in cleaned):
        return None
    return cleaned


def _validate_signature(value):
    '''Returns the signature unchanged, or None if the value is invalid.'''
    if not isinstance(value, str):
        return None
    if len(value) > MAX_SIGNATURE_LENGTH:
        return None
    if any((ord(ch) < 32 and ch not in '\n\t') or ord(ch) == 127 for ch in value):
        return None
    return value


def _validate_app(value):
    '''Returns the validated `app` preference map, or None if it is invalid.

    Unknown keys are rejected rather than silently dropped so a client typo
    surfaces as a 400 instead of a preference that never persists.
    '''
    if not isinstance(value, dict):
        return None
    cleaned = {}
    for key, val in value.items():
        if key in APP_ALLOWED:
            if val not in APP_ALLOWED[key]:
                return None
            cleaned[key] = val
        elif key == 'default_from_address':
            address = _validate_name(val)
            if address is None:
                return None
            cleaned[key] = address
        elif key == 'signature':
            signature = _validate_signature(val)
            if signature is None:
                return None
            cleaned[key] = signature
        else:
            return None
    return cleaned


def _build_updates(body):
    '''Validates the request body into the DynamoDB update map.

    Raises ValueError with a client-facing message on any invalid field, so the
    handler keeps a single 400 exit. Keeps validation for all four surfaces
    (theme/accent/density, name, and the Apple `app` map) in one place.
    '''
    updates = {}
    for key, allowed in ALLOWED.items():
        if key in body:
            if body[key] not in allowed:
                raise ValueError(f'Invalid value for {key}.')
            updates[key] = body[key]
    if 'name' in body:
        name = _validate_name(body['name'])
        if name is None:
            raise ValueError('Invalid value for name.')
        updates['name'] = name
    if 'app' in body:
        app = _validate_app(body['app'])
        if app is None:
            raise ValueError('Invalid value for app.')
        updates['app'] = app
    if not updates:
        raise ValueError('No known preference keys supplied.')
    return updates


def _build_expression(flat, app):
    '''Builds the UpdateExpression pieces for the flat keys and the nested
    `app` keys. Every name is aliased - `name` is a DynamoDB reserved word,
    and the `app` member names are aliased for uniformity.'''
    sets = []
    names = {}
    values = {}
    for i, key in enumerate(flat):
        sets.append(f'#k{i} = :v{i}')
        names[f'#k{i}'] = key
        values[f':v{i}'] = flat[key]
    if app:
        names['#app'] = 'app'
        for j, key in enumerate(app):
            sets.append(f'#app.#a{j} = :a{j}')
            names[f'#a{j}'] = key
            values[f':a{j}'] = app[key]
    return sets, names, values


def _ensure_app_map(user):
    '''Creates the row's `app` map if it does not exist yet, so the nested
    per-key SETs in the main update cannot fail on a missing document path.
    A separate write because DynamoDB rejects overlapping document paths
    (`app` and `app.x`) in a single update expression. Idempotent and
    non-destructive (`if_not_exists`), so a race between two first saves is
    harmless.'''
    table.update_item(
        Key={'user': user},
        UpdateExpression='SET #app = if_not_exists(#app, :empty)',
        ExpressionAttributeNames={'#app': 'app'},
        ExpressionAttributeValues={':empty': {}},
    )


def handler(event, _context):
    '''Validates and merges the caller's preferences into their row.'''
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    try:
        body = json.loads(event.get('body') or '{}')
    except (TypeError, ValueError):
        return {
            'statusCode': 400,
            'body': json.dumps({'Error': 'Invalid JSON body.'})
        }
    try:
        updates = _build_updates(body)
    except ValueError as err:
        return {
            'statusCode': 400,
            'body': json.dumps({'Error': str(err)})
        }
    # Merge rather than replace, at BOTH levels. Top level: clients save only
    # the keys they own (the React app sends theme/accent/density, the Apple
    # clients send name and the `app` map), so a put_item here would clobber
    # the other client's preferences. Inside `app`: each member merges
    # individually (`app.x = :v`), so a client that predates a newer client's
    # preference key cannot delete it by saving its own, older set -
    # concurrent multi-device edits are last-write-wins per key. A replace
    # here would let one stale device silently wipe every newer setting.
    app = updates.pop('app', None)
    sets, names, values = _build_expression(updates, app)
    try:
        if app:
            _ensure_app_map(user)
        # `{"app": {}}` validates to an empty merge - nothing to write. (The
        # old wholesale replace would have wiped the map here; there is no
        # legitimate caller for that.)
        if sets:
            table.update_item(
                Key={'user': user},
                UpdateExpression='SET ' + ', '.join(sets),
                ExpressionAttributeNames=names,
                ExpressionAttributeValues=values,
            )
    except Exception as err:  # pylint: disable=broad-exception-caught
        return {
            'statusCode': 500,
            'body': json.dumps({'Error': str(err)})
        }
    if app is not None:
        updates['app'] = app
    return {
        'statusCode': 200,
        'body': json.dumps(updates)
    }
