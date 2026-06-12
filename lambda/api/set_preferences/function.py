'''Persists the current user's preferences (theme/accent/density/name).'''
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
    updates = {}
    for key, allowed in ALLOWED.items():
        if key in body:
            value = body[key]
            if value not in allowed:
                return {
                    'statusCode': 400,
                    'body': json.dumps({'Error': f'Invalid value for {key}.'})
                }
            updates[key] = value
    if 'name' in body:
        name = _validate_name(body['name'])
        if name is None:
            return {
                'statusCode': 400,
                'body': json.dumps({'Error': 'Invalid value for name.'})
            }
        updates['name'] = name
    if not updates:
        return {
            'statusCode': 400,
            'body': json.dumps({'Error': 'No known preference keys supplied.'})
        }
    # Merge rather than replace: clients save only the keys they own (the
    # React app sends accent/density, the Apple clients send name), so a
    # put_item here would clobber the other client's preferences. Every key
    # is aliased - `name` is a DynamoDB reserved word.
    expression = ', '.join(f'#k{i} = :v{i}' for i in range(len(updates)))
    names = {f'#k{i}': key for i, key in enumerate(updates)}
    values = {f':v{i}': updates[key] for i, key in enumerate(updates)}
    try:
        table.update_item(
            Key={'user': user},
            UpdateExpression=f'SET {expression}',
            ExpressionAttributeNames=names,
            ExpressionAttributeValues=values,
        )
    except Exception as err:  # pylint: disable=broad-exception-caught
        return {
            'statusCode': 500,
            'body': json.dumps({'Error': str(err)})
        }
    return {
        'statusCode': 200,
        'body': json.dumps(updates)
    }
