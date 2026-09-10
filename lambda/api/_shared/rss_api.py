'''Shared plumbing for the RSS API Lambdas (docs/1.x/rss-implementation-plan.md,
phase 3): request/response envelope, the per-user identity, table handles,
key conventions, and the read-state rules every endpoint must apply the
same way.

Deliberately independent of helper.py, which pulls in the IMAP stack and
reads the master password at import; the RSS endpoints touch only DynamoDB,
S3, and SQS.

Key conventions (see the data model in the plan):
  feed.owner_key        SHARED_OWNER for a public feed, else the username
  subscription.folder_key   "<folder_id or ROOT_FOLDER>#<subscription_id>"
  user_item_state PK    "<user>#<feed_id>" (user_feed_key)
  item / state SK       "<published_at_iso>#<item_id>" (sort_key)

Read state is COMPUTED: an item is read when its state row says so, or,
absent an explicit row, when it was published at or before the
subscription's read_watermark (what mark-all-read writes). A never-touched
item has no row and is unread.
'''
import base64
import json
import os
from decimal import Decimal
import boto3  # pylint: disable=import-error
from boto3.dynamodb.conditions import Key  # pylint: disable=import-error

FEED_TABLE = 'cabal-rss-feed'
ITEM_TABLE = 'cabal-rss-item'
SUBSCRIPTION_TABLE = 'cabal-rss-subscription'
FOLDER_TABLE = 'cabal-rss-folder'
STATE_TABLE = 'cabal-rss-user-item-state'
SHARED_OWNER = '~shared'
ROOT_FOLDER = '~root'
CONTROL_DOMAIN = os.environ.get('CONTROL_DOMAIN', '')
CACHE_BUCKET = os.environ.get('RSS_CACHE_BUCKET', f'rss-cache.{CONTROL_DOMAIN}')

ORDERING_MODES = ('newest_first', 'oldest_first',
                  'newest_day_oldest_within', 'oldest_day_newest_within')
OPEN_MODES = ('summary', 'article')
STYLING_MODES = ('reader', 'native')
MAX_TITLE_LENGTH = 256
MAX_PAGE = 100
DEFAULT_PAGE = 50

ddb = boto3.resource('dynamodb')
feeds = ddb.Table(FEED_TABLE)
items = ddb.Table(ITEM_TABLE)
subscriptions = ddb.Table(SUBSCRIPTION_TABLE)
folders = ddb.Table(FOLDER_TABLE)
state = ddb.Table(STATE_TABLE)
s3 = boto3.client('s3')


class ApiError(Exception):
    '''A client-visible failure. `code` is a stable machine-readable token
    (documented in docs/rss.md); `message` is for humans.'''

    def __init__(self, status, code, message):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message


# -- Envelope --------------------------------------------------------------

def username(event):
    '''The caller's Cognito username, the per-user key everywhere.'''
    return event['requestContext']['authorizer']['claims']['cognito:username']


def body_of(event):
    '''The JSON request body as a dict (empty when absent).'''
    raw = event.get('body') or '{}'
    try:
        body = json.loads(raw)
    except (TypeError, ValueError) as err:
        raise ApiError(400, 'invalid_json', 'Request body is not valid JSON.') from err
    if not isinstance(body, dict):
        raise ApiError(400, 'invalid_json', 'Request body must be a JSON object.')
    return body


def params_of(event):
    '''Query-string parameters as a dict (empty when absent).'''
    return event.get('queryStringParameters') or {}


def ok(payload):
    '''200 with a JSON body; Decimals become numbers.'''
    return {'statusCode': 200, 'body': json.dumps(plain(payload))}


def error(err):
    '''The error envelope: {"Error": message, "code": token}. `Error` is the
    key every other endpoint in this API uses.'''
    return {'statusCode': err.status,
            'body': json.dumps({'Error': err.message, 'code': err.code})}


def guarded(handler):
    '''Decorator: ApiError -> its envelope; anything else -> 500 with the
    message, matching the rest of the API.'''
    def wrapper(event, context):
        try:
            return handler(event, context)
        except ApiError as err:
            return error(err)
        except Exception as err:  # pylint: disable=broad-exception-caught
            print(f'[rss-api] unhandled: {err!r}')
            return {'statusCode': 500, 'body': json.dumps({'Error': str(err)})}
    return wrapper


def plain(value):
    '''DynamoDB Decimals to int/float, recursively, for json.dumps.'''
    if isinstance(value, Decimal):
        return int(value) if value == value.to_integral_value() else float(value)
    if isinstance(value, dict):
        return {k: plain(v) for k, v in value.items()}
    if isinstance(value, (list, tuple, set)):
        return [plain(v) for v in value]
    return value


# -- Keys --------------------------------------------------------------------

def user_feed_key(user, feed_id):
    '''Partition key of the per-user per-item state table.'''
    return f'{user}#{feed_id}'


def folder_key(folder_id, subscription_id):
    '''Range key of the by_user_folder index.'''
    return f'{folder_id or ROOT_FOLDER}#{subscription_id}'


def encode_cursor(payload):
    '''Opaque pagination cursor (base64 JSON). Clients never inspect it.'''
    return base64.urlsafe_b64encode(json.dumps(plain(payload)).encode()).decode()


def decode_cursor(cursor):
    '''The dict behind encode_cursor, or ApiError for a malformed one.'''
    if not cursor:
        return {}
    try:
        return json.loads(base64.urlsafe_b64decode(cursor.encode()))
    except (ValueError, TypeError) as err:
        raise ApiError(400, 'invalid_cursor', 'The cursor is not valid.') from err


def page_size(params):
    '''`limit` bounded to [1, MAX_PAGE], default DEFAULT_PAGE.'''
    try:
        return max(1, min(MAX_PAGE, int(params.get('limit', DEFAULT_PAGE))))
    except (TypeError, ValueError) as err:
        raise ApiError(400, 'invalid_limit', 'limit must be an integer.') from err


# -- Lookups -------------------------------------------------------------------

def get_subscription(user, subscription_id):
    '''The caller's subscription row, or ApiError 404.'''
    if not subscription_id:
        raise ApiError(400, 'missing_subscription', 'subscription_id is required.')
    row = subscriptions.get_item(Key={'user': user, 'subscription_id': subscription_id}).get('Item')
    if not row:
        raise ApiError(404, 'unknown_subscription', 'No such subscription.')
    return row


def list_subscriptions(user):
    '''Every subscription row of the caller.'''
    rows = []
    kwargs = {'KeyConditionExpression': Key('user').eq(user)}
    while True:
        response = subscriptions.query(**kwargs)
        rows.extend(response.get('Items', []))
        if 'LastEvaluatedKey' not in response:
            return rows
        kwargs['ExclusiveStartKey'] = response['LastEvaluatedKey']


def list_folders(user):
    '''Every folder row of the caller.'''
    rows = []
    kwargs = {'KeyConditionExpression': Key('user').eq(user)}
    while True:
        response = folders.query(**kwargs)
        rows.extend(response.get('Items', []))
        if 'LastEvaluatedKey' not in response:
            return rows
        kwargs['ExclusiveStartKey'] = response['LastEvaluatedKey']


def folder_and_descendants(user, folder_id):
    '''The folder id plus every folder nested under it; ApiError 404 if the
    folder does not exist.'''
    rows = list_folders(user)
    by_parent = {}
    ids = {row['folder_id'] for row in rows}
    if folder_id not in ids:
        raise ApiError(404, 'unknown_folder', 'No such folder.')
    for row in rows:
        parent = row.get('parent_folder_id') or ROOT_FOLDER
        by_parent.setdefault(parent, []).append(row['folder_id'])
    wanted, frontier = {folder_id}, [folder_id]
    while frontier:
        current = frontier.pop()
        for child in by_parent.get(current, []):
            if child not in wanted:
                wanted.add(child)
                frontier.append(child)
    return wanted


def batch_get(table_name, keys, projection=None):
    '''BatchGetItem in chunks of 100 with unprocessed-key retry; returns rows.'''
    rows = []
    for start in range(0, len(keys), 100):
        request = {'Keys': keys[start:start + 100]}
        if projection:
            request['ProjectionExpression'] = projection
        pending = {table_name: request}
        while pending:
            response = ddb.batch_get_item(RequestItems=pending)
            rows.extend(response.get('Responses', {}).get(table_name, []))
            pending = response.get('UnprocessedKeys') or {}
    return rows


def state_map(user, feed_id, sort_keys):
    '''{sort_key: state row} for the given items of one feed.'''
    if not sort_keys:
        return {}
    key = user_feed_key(user, feed_id)
    rows = batch_get(STATE_TABLE, [{'user_feed': key, 'sort_key': sk} for sk in sort_keys])
    return {row['sort_key']: row for row in rows}


# -- Read state and serialization ------------------------------------------------

def is_read(state_row, published_at, watermark):
    '''The rule from the module docstring.'''
    if state_row is not None and 'is_read' in state_row:
        return bool(state_row['is_read'])
    return bool(watermark) and str(published_at) <= str(watermark)


def serialize_item(row, subscription, state_row, inline_body=True):
    '''Wire form of one item with the caller's state folded in.'''
    out = {
        'feed_id': row['feed_id'],
        'subscription_id': subscription['subscription_id'],
        'item_id': row.get('item_id', ''),
        'sort_key': row['sort_key'],
        'guid': row.get('guid', ''),
        'title': row.get('title', ''),
        'author': row.get('author', ''),
        'url': row.get('url', ''),
        'published_at': row.get('published_at', ''),
        'updated_at': row.get('updated_at', ''),
        'fetched_at': row.get('fetched_at', ''),
        'fetched_key': row.get('fetched_key', ''),
        'summary_html': row.get('summary_html', ''),
        'content_html': row.get('content_html', ''),
        'is_read': is_read(state_row, row.get('published_at', ''),
                           subscription.get('read_watermark')),
        'is_favorite': bool(state_row.get('is_favorite')) if state_row else False,
    }
    if inline_body and not out['content_html'] and row.get('content_s3_key'):
        out['content_html'] = spilled_body(row['content_s3_key'])
    return out


def spilled_body(key):
    '''An oversized body from the rss-cache bucket; empty if it is gone.'''
    try:
        body = s3.get_object(Bucket=CACHE_BUCKET, Key=key)['Body'].read()
        return body.decode('utf-8', 'replace')
    except Exception as err:  # pylint: disable=broad-exception-caught
        print(f'[rss-api] spilled body {key} unreadable: {err}')
        return ''


def feed_summary(row):
    '''The feed fields clients need beside a subscription (title, site, health).'''
    if not row:
        return None
    return {
        'feed_id': row['feed_id'],
        'canonical_url': row.get('canonical_url', ''),
        'feed_type': row.get('feed_type', ''),
        'title': row.get('title', ''),
        'description': row.get('description', ''),
        'site_url': row.get('site_url', ''),
        'item_count': row.get('item_count', 0),
        'last_fetched_at': row.get('last_fetched_at', ''),
        'last_attempt_at': row.get('last_attempt_at', ''),
        'last_status_code': row.get('last_status_code', 0),
        'last_error': row.get('last_error', ''),
        'consecutive_failure_count': row.get('consecutive_failure_count', 0),
        'cadence_minutes': row.get('cadence_minutes', 0),
        'next_fetch_at': row.get('next_fetch_at', ''),
        'dead_lettered': 'due_shard' not in row,
    }


def serialize_subscription(row, feed_row=None):
    '''Wire form of a subscription row.'''
    return {
        'subscription_id': row['subscription_id'],
        'feed_id': row['feed_id'],
        'folder_id': row.get('folder_id') or '',
        'custom_title': row.get('custom_title', ''),
        'ordering_mode': row.get('ordering_mode', ORDERING_MODES[0]),
        'default_open_mode': row.get('default_open_mode', OPEN_MODES[0]),
        'default_styling': row.get('default_styling', STYLING_MODES[0]),
        'notifications_enabled': bool(row.get('notifications_enabled', False)),
        'credentials_scheme': row.get('credentials_scheme') or '',
        'read_watermark': row.get('read_watermark', ''),
        'data_store_uuid': row.get('data_store_uuid', ''),
        'created_at': row.get('created_at', ''),
        'feed': feed_summary(feed_row),
    }


def serialize_folder(row):
    '''Wire form of a folder row.'''
    return {
        'folder_id': row['folder_id'],
        'parent_folder_id': row.get('parent_folder_id') or '',
        'name': row.get('name', ''),
        'display_order': row.get('display_order', 0),
    }
