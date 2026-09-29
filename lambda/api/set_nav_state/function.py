'''Persists the current user's navigation cursor (last folder/message/scroll).

The cursor is a single logical value owned by whichever client is currently
active, so this handler replaces the whole `nav_state` attribute rather than
merging keys. It lives on its own attribute of the `cabal-user-preferences`
row, so writing it never disturbs theme/accent/density/name (which the
`set_preferences` handler owns). The server stamps `updated_at` so clients
cannot lie about recency, and records the originating `client_id` so a second
client can tell "this cursor came from somewhere else" and offer to follow it
instead of silently overwriting it.

Two kinds of cursor share the attribute (resume-session plan, Phase C):

- `mail` (the default; `kind` omitted): `folder` required, plus the message
  identity and scroll fields below.
- `rss`: a feed item being read. `rss_item` (`<feed_id>#<sort_key>`, the
  item's id) is required and `folder` is not stored; `rss_scope` is the
  optional list scope token (`all`, `sub:<id>`, `folder:<id>`) it was read
  from. Shipped clients that predate it decode a folder-less cursor as
  "nothing to restore", so writing one never breaks them.

Either kind may carry the reading position: `msg_anchor` (the Apple
element anchor `i<path>|<delta>`, or the `f<fraction>` form) and
`msg_fraction` (the same position as a 0-1 fraction of the scrollable
height), so a client that can only apply a fraction still can.
'''
import json
import math
import os
import time
from decimal import Decimal
import boto3  # pylint: disable=import-error

ddb = boto3.resource('dynamodb')
TABLE_NAME = os.environ.get('USER_PREFERENCES_TABLE_NAME', 'cabal-user-preferences')
table = ddb.Table(TABLE_NAME)

# Folder paths and Message-IDs are bounded well below these caps in practice;
# the limits exist only to stop an unbounded blob being parked on the row.
MAX_FOLDER_LENGTH = 1024
MAX_MESSAGE_ID_LENGTH = 998   # RFC 5322 line-length ceiling for a Message-ID
MAX_CLIENT_ID_LENGTH = 64
# In-message scroll anchor: a compact structural pointer the Apple client
# builds for HTML bodies (a child-index path plus a small pixel delta, e.g.
# "i2.0.5|-12"). Opaque to the server; the cap just stops an unbounded blob.
MAX_ANCHOR_LENGTH = 512
# A feed item id (`<feed_id>#<sort_key>`) and a list scope token.
MAX_RSS_ITEM_LENGTH = 1024
MAX_RSS_SCOPE_LENGTH = 256
CURSOR_KINDS = ('mail', 'rss')
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


def _clean_fraction(value):
    '''Returns a 0-1 fraction as a 4-place Decimal (DynamoDB has no float), or None.'''
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if math.isnan(value) or value < 0 or value > 1:
        return None
    return Decimal(str(round(float(value), 4)))


def _error(message):
    '''A 400 with the given message.'''
    return {'statusCode': 400, 'body': json.dumps({'Error': message})}


def _identity(body):  # pylint: disable=too-many-return-statements
    '''(nav_state seed, error) for the cursor's kind and its required identity.'''
    kind = body.get('kind') or 'mail'
    if kind not in CURSOR_KINDS:
        return None, _error('kind must be mail or rss.')
    client_id = _clean_str(body.get('client_id'), MAX_CLIENT_ID_LENGTH)
    if kind == 'rss':
        rss_item = _clean_str(body.get('rss_item'), MAX_RSS_ITEM_LENGTH)
        if rss_item is None or '#' not in rss_item:
            return None, _error('An rss cursor needs rss_item (<feed_id>#<sort_key>).')
        if client_id is None:
            return None, _error('A non-empty client_id is required.')
        seed = {'kind': 'rss', 'rss_item': rss_item}
        if body.get('rss_scope') is not None:
            rss_scope = _clean_str(body.get('rss_scope'), MAX_RSS_SCOPE_LENGTH)
            if rss_scope is None:
                return None, _error('Invalid value for rss_scope.')
            seed['rss_scope'] = rss_scope
        seed['client_id'] = client_id
        return seed, None
    # folder and client_id are mandatory for a mail cursor.
    folder = _clean_str(body.get('folder'), MAX_FOLDER_LENGTH)
    if folder is None:
        return None, _error('A non-empty folder is required.')
    if client_id is None:
        return None, _error('A non-empty client_id is required.')
    return {'folder': folder, 'client_id': client_id}, None


def _apply_optional(body, nav_state):
    '''Copies the validated optional fields into nav_state; returns a 400 or None.'''
    # Optional string field: the durable message identity that survives moves.
    if body.get('message_id') is not None:
        message_id = _clean_str(body.get('message_id'), MAX_MESSAGE_ID_LENGTH)
        if message_id is None:
            return _error('Invalid value for message_id.')
        nav_state['message_id'] = message_id

    # Optional string field: the in-message scroll anchor (HTML bodies).
    if body.get('msg_anchor') is not None:
        msg_anchor = _clean_str(body.get('msg_anchor'), MAX_ANCHOR_LENGTH)
        if msg_anchor is None:
            return _error('Invalid value for msg_anchor.')
        nav_state['msg_anchor'] = msg_anchor

    # Optional fraction: the reading position a client without element
    # anchors can apply (Android's body view runs with JavaScript off).
    if body.get('msg_fraction') is not None:
        msg_fraction = _clean_fraction(body.get('msg_fraction'))
        if msg_fraction is None:
            return _error('msg_fraction must be a number from 0 to 1.')
        nav_state['msg_fraction'] = msg_fraction

    # Optional whole-number fields: IMAP coordinates and scroll offsets.
    for key in ('uid', 'uid_validity', 'list_scroll', 'msg_scroll'):
        if body.get(key) is not None:
            number = _clean_int(body.get(key))
            if number is None:
                return _error(f'Invalid value for {key}.')
            nav_state[key] = number
    return None


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

    nav_state, error = _identity(body)
    if error is not None:
        return error
    # Server-stamped so recency cannot be forged. Epoch milliseconds.
    nav_state['updated_at'] = int(time.time() * 1000)

    error = _apply_optional(body, nav_state)
    if error is not None:
        return error

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
        'body': json.dumps(nav_state, default=float)
    }
