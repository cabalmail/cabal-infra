'''Persists the current user's navigation cursor (last folder/message/scroll).

The cursor is a single logical value owned by whichever client is currently
active, so this handler replaces the whole `nav_state` attribute rather than
merging keys. It lives on its own attribute of the `cabal-user-preferences`
row, so writing it never disturbs theme/accent/density/name (which the
`set_preferences` handler owns). The server stamps `updated_at` so clients
cannot lie about recency, and records the originating `client_id` so a second
client can tell "this cursor came from somewhere else" and offer to follow it
instead of silently overwriting it.
'''
import json
import os
import time
import boto3  # pylint: disable=import-error

ddb = boto3.resource('dynamodb')
TABLE_NAME = os.environ.get('USER_PREFERENCES_TABLE_NAME', 'cabal-user-preferences')
table = ddb.Table(TABLE_NAME)

# Folder paths and Message-IDs are bounded well below these caps in practice;
# the limits exist only to stop an unbounded blob being parked on the row.
MAX_FOLDER_LENGTH = 1024
MAX_MESSAGE_ID_LENGTH = 998   # RFC 5322 line-length ceiling for a Message-ID
MAX_CLIENT_ID_LENGTH = 64
# Whole-number ceiling shared by uid/uid_validity/scroll offsets - large enough
# for any real IMAP UID or pixel offset, small enough to reject garbage.
MAX_NUMBER = 2 ** 53


def _clean_str(value, max_length):
    '''Returns a trimmed control-character-free string, or None if invalid.'''
    if not isinstance(value, str):
        return None
    cleaned = value.strip()
    if not cleaned or len(cleaned) > max_length:
        return None
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in cleaned):
        return None
    return cleaned


def _clean_int(value):
    '''Returns a non-negative bounded int, or None if invalid.'''
    # bool is an int subclass; reject it so True/False can't masquerade as 0/1.
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    if value < 0 or value > MAX_NUMBER:
        return None
    return value


def handler(event, _context):  # pylint: disable=too-many-return-statements
    '''Validates the submitted cursor and replaces the caller's nav_state.'''
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    try:
        body = json.loads(event.get('body') or '{}')
    except (TypeError, ValueError):
        return {
            'statusCode': 400,
            'body': json.dumps({'Error': 'Invalid JSON body.'})
        }
    if not isinstance(body, dict):
        return {
            'statusCode': 400,
            'body': json.dumps({'Error': 'Body must be a JSON object.'})
        }

    # folder and client_id are mandatory; everything else is optional context.
    folder = _clean_str(body.get('folder'), MAX_FOLDER_LENGTH)
    if folder is None:
        return {
            'statusCode': 400,
            'body': json.dumps({'Error': 'A non-empty folder is required.'})
        }
    client_id = _clean_str(body.get('client_id'), MAX_CLIENT_ID_LENGTH)
    if client_id is None:
        return {
            'statusCode': 400,
            'body': json.dumps({'Error': 'A non-empty client_id is required.'})
        }

    nav_state = {
        'folder': folder,
        'client_id': client_id,
        # Server-stamped so recency cannot be forged. Epoch milliseconds.
        'updated_at': int(time.time() * 1000),
    }

    # Optional string field: the durable message identity that survives moves.
    if body.get('message_id') is not None:
        message_id = _clean_str(body.get('message_id'), MAX_MESSAGE_ID_LENGTH)
        if message_id is None:
            return {
                'statusCode': 400,
                'body': json.dumps({'Error': 'Invalid value for message_id.'})
            }
        nav_state['message_id'] = message_id

    # Optional whole-number fields: IMAP coordinates and scroll offsets.
    for key in ('uid', 'uid_validity', 'list_scroll', 'msg_scroll'):
        if body.get(key) is not None:
            number = _clean_int(body.get(key))
            if number is None:
                return {
                    'statusCode': 400,
                    'body': json.dumps({'Error': f'Invalid value for {key}.'})
                }
            nav_state[key] = number

    try:
        table.update_item(
            Key={'user': user},
            UpdateExpression='SET nav_state = :ns',
            ExpressionAttributeValues={':ns': nav_state},
        )
    except Exception as err:  # pylint: disable=broad-exception-caught
        return {
            'statusCode': 500,
            'body': json.dumps({'Error': str(err)})
        }
    return {
        'statusCode': 200,
        'body': json.dumps(nav_state)
    }
