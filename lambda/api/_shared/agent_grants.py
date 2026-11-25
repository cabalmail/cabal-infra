'''Agent access grants: the token format, its hash, and the cabal-agent-grants
row shape shared by the grant-management endpoints and the /mcp authorizer.

Phase A of docs/1.x/agent-mail-access-plan.md. A grant is a bearer token
a user mints for an AI assistant. Only the token's SHA-256 is stored; the
plaintext is returned once, at mint time, and never again.

Deliberately depends on only boto3 (provided by the Lambda runtime) and the
standard library, like admin_limits.py: the grant endpoints and the authorizer
never open IMAP, so they must not pull in helper.py's imapclient import or its
module-load master-password fetch.
'''
import hashlib
import json
import re
import secrets
import time
import boto3  # pylint: disable=import-error
from boto3.dynamodb.conditions import Key  # pylint: disable=import-error

GRANTS_TABLE = 'cabal-agent-grants'
USER_INDEX = 'user-index'

TOKEN_PREFIX = 'cbl_agt_'
# 32 bytes of entropy, urlsafe-base64 (43 characters).
_TOKEN_BYTES = 32
_TOKEN_RE = re.compile(r'^cbl_agt_[A-Za-z0-9_-]{43}$')

# A grant id is the head of the token hash: enough to name a grant in a list
# or a revoke call, and useless for presenting the token.
_GRANT_ID_LEN = 16
_GRANT_ID_RE = re.compile(r'^[0-9a-f]{16}$')

ACCESS_READ_ONLY = 'read_only'
ACCESS_READ_WRITE = 'read_write'
# Phase A ships read-only grants only. read_write is accepted by the data model
# so the row shape does not change in Phase B, but minting one is refused.
MINTABLE_ACCESS = (ACCESS_READ_ONLY,)

# Phase A ships INBOX-only grants. The row carries a folder list so widening
# scope later is a validation change, not a schema change.
MINTABLE_FOLDERS = ('INBOX',)

DEFAULT_EXPIRY_DAYS = 90
MAX_EXPIRY_DAYS = 365
MAX_ACTIVE_GRANTS = 10
MAX_LABEL_LEN = 64
_LABEL_FORBIDDEN_RE = re.compile(r'[\x00-\x1f\x7f]')

_TABLE_CACHE = {}


def grants_table():
    '''The cabal-agent-grants table, created on first use so importing this
    module costs nothing in a test that never touches DynamoDB.'''
    if 'table' not in _TABLE_CACHE:
        _TABLE_CACHE['table'] = boto3.resource('dynamodb').Table(GRANTS_TABLE)
    return _TABLE_CACHE['table']


def new_token():
    '''Returns a fresh plaintext grant token.'''
    return TOKEN_PREFIX + secrets.token_urlsafe(_TOKEN_BYTES)


def is_token_shaped(value):
    '''True when `value` has the exact shape new_token produces. Checked before
    any table read, so a JWT or other credential is refused without a lookup.'''
    return isinstance(value, str) and bool(_TOKEN_RE.match(value))


def token_hash(token):
    '''Hex SHA-256 of a token: the table's hash key.'''
    return hashlib.sha256(token.encode('ascii')).hexdigest()


def grant_id_for(hashed):
    '''The public id of the grant whose token hashes to `hashed`.'''
    return hashed[:_GRANT_ID_LEN]


def validate_grant_id(value):
    '''Returns `value` if it is a grant id, else raises ValueError.'''
    if not isinstance(value, str) or not _GRANT_ID_RE.match(value):
        raise ValueError('grant_id must be 16 lowercase hex characters')
    return value


def validate_label(value):
    '''A grant's user-chosen name, e.g. "Claude on my laptop".'''
    if not isinstance(value, str) or not value.strip():
        raise ValueError('label is required')
    value = value.strip()
    if len(value) > MAX_LABEL_LEN:
        raise ValueError(f'label is too long (max {MAX_LABEL_LEN} characters)')
    if _LABEL_FORBIDDEN_RE.search(value):
        raise ValueError('label contains control characters')
    return value


def validate_expiry_days(value):
    '''Days until the grant expires: 1 to MAX_EXPIRY_DAYS, default 90.'''
    if value is None:
        return DEFAULT_EXPIRY_DAYS
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError('expires_in_days must be a whole number')
    if value < 1 or value > MAX_EXPIRY_DAYS:
        raise ValueError(f'expires_in_days must be between 1 and {MAX_EXPIRY_DAYS}')
    return value


def validate_access(value):
    '''The grant's access level. Only read_only can be minted in Phase A.'''
    if value is None:
        return ACCESS_READ_ONLY
    if value not in MINTABLE_ACCESS:
        raise ValueError(f'access must be one of: {", ".join(MINTABLE_ACCESS)}')
    return value


def validate_folders(value):
    '''The folders in scope. Only INBOX can be granted in Phase A.'''
    if value is None:
        return list(MINTABLE_FOLDERS)
    if not isinstance(value, list) or not value:
        raise ValueError('folders must be a non-empty list')
    if any(folder not in MINTABLE_FOLDERS for folder in value):
        raise ValueError(f'folders may only contain: {", ".join(MINTABLE_FOLDERS)}')
    return sorted(set(value))


def is_live(item, now=None):
    '''True when a grant row is neither revoked nor expired.

    DynamoDB's TTL sweep can lag expiry by up to two days, so expiry is checked
    here rather than trusted to the row having been deleted.'''
    if not item or item.get('revoked_at'):
        return False
    now = int(time.time()) if now is None else now
    try:
        return int(item.get('expires_at', 0)) > now
    except (TypeError, ValueError):
        return False


def public_view(item, now=None):
    '''The fields of a grant row a user may see. Never the token hash.'''
    def _int_or_none(value):
        return int(value) if value is not None else None
    return {
        'grant_id': item.get('grant_id'),
        'label': item.get('label'),
        'folders': sorted(item.get('folders') or []),
        'access': item.get('access'),
        'created_at': _int_or_none(item.get('created_at')),
        'expires_at': _int_or_none(item.get('expires_at')),
        'last_used_at': _int_or_none(item.get('last_used_at')),
        'revoked': bool(item.get('revoked_at')),
        'live': is_live(item, now),
    }


def user_grants(user):
    '''Every grant row the user owns, live or not.'''
    table = grants_table()
    items = []
    kwargs = {
        'IndexName': USER_INDEX,
        'KeyConditionExpression': Key('user').eq(user),
    }
    while True:
        page = table.query(**kwargs)
        items.extend(page.get('Items', []))
        if 'LastEvaluatedKey' not in page:
            return items
        kwargs['ExclusiveStartKey'] = page['LastEvaluatedKey']


def response(status, body):
    '''API Gateway proxy response with a JSON body.'''
    return {'statusCode': status, 'body': json.dumps(body)}


def caller(event):
    '''The Cognito username of the caller of a grant-management endpoint.'''
    return event['requestContext']['authorizer']['claims']['cognito:username']


def json_object_body(event):
    '''Parses the request body as a JSON object, returning (body, error).

    An absent body is an empty object, since every field the grant endpoints
    read has a default or is checked by its own validator.'''
    raw = event.get('body')
    if not raw:
        return {}, None
    try:
        body = json.loads(raw)
    except (TypeError, json.JSONDecodeError):
        return None, response(400, {'status': 'Invalid input: request body is not valid JSON'})
    if not isinstance(body, dict):
        return None, response(400, {'status': 'Invalid input: request body must be a JSON object'})
    return body, None
