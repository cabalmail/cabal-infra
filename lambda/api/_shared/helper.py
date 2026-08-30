'''Shared helpers for the Cabalmail Lambda API: IMAP client/auth, DynamoDB
address lookups, S3 message caching and presigned URLs, envelope decoding, and
the request-input validators used across the handlers.'''
# This is a deliberately broad shared module; it sits just over pylint's
# 1000-line max-module-lines heuristic. Splitting it into topical modules is
# worthwhile but out of scope here, and would mean teaching build-api-one.sh a
# new per-module bundling rule for every consumer zip.
# pylint: disable=too-many-lines
import base64
import email
import functools
import io
import json
import logging
import os
import re
import time
from email.header import decode_header
from email.parser import HeaderParser
from email.policy import default as default_policy
import boto3  # pylint: disable=import-error
from botocore.exceptions import ClientError  # pylint: disable=import-error
from imap_session import open_imap_client  # pylint: disable=import-error

TABLE = 'cabal-addresses'
region = os.environ['AWS_REGION']
ddb = boto3.resource('dynamodb')
ddb_table = ddb.Table(TABLE)
user_domain_access_table = ddb.Table('cabal-user-domain-access')
s3r = boto3.resource("s3")
s3c = boto3.client("s3",
                  region_name=region,
                  config=boto3.session.Config(signature_version='s3v4'))

ssm = boto3.client('ssm')
mpw = ssm.get_parameter(Name='/cabal/master_password',
                        WithDecryption=True)["Parameter"]["Value"]

def get_mpw():
    """Returns the master password"""
    return mpw


# Canonical mail-tier endpoints and cache bucket, derived server-side from the
# environment's control domain -- NEVER from a request field.
#
# The IMAP/SMTP host and the S3 cache bucket used to be taken from a client
# `host`/`smtp_host` parameter (bucket = host.replace("imap","cache")). Because
# get_imap_client logs in with the shared master password ({user}*admin / SMTP
# `master`), a client-chosen host let any authenticated user point the
# connection at a server they control and capture that master credential -- a
# full multi-tenant compromise. These values are fixed per environment (the ELB
# publishes imap.<domain>/smtp-out.<domain>; the bucket is cache.<domain>), so
# we derive them here and ignore whatever the client sends. `.get` with a blank
# default keeps helper importable in any function that lacks CONTROL_DOMAIN;
# such functions never touch these paths.
CONTROL_DOMAIN = os.environ.get('CONTROL_DOMAIN', '')
IMAP_HOST = f'imap.{CONTROL_DOMAIN}'
SMTP_HOST = f'smtp-out.{CONTROL_DOMAIN}'
CACHE_BUCKET = f'cache.{CONTROL_DOMAIN}'


# ---------------------------------------------------------------------------
# Planned-maintenance signal.
#
# The IMAP service is hard-capped at one ECS task (Dovecot has Maildir-over-EFS
# concurrency issues), so every IMAP image roll has a true zero-task window: the
# old container stops before the new one starts. During that window a fresh IMAP
# connection fails, and without this the handlers would relay a raw 500/timeout
# that clients render as a scary error.
#
# A planned roll writes /cabal/maintenance/imap = {"active": true, ...} before
# triggering the roll; the new container clears it once Dovecot is back.
# get_imap_client() consults the flag and raises MaintenanceError instead of
# dialing a dead server, and the maintenance_guard decorator turns that into a
# friendly 503 + Retry-After. A cache-served read (get_message hit) never calls
# get_imap_client, so it keeps working through the window.
#
# Fail-open everywhere: a missing parameter, an unparseable value, an IAM gap,
# or any SSM error is treated as "not in maintenance" so a flag-read hiccup can
# never wedge mail access.
# ---------------------------------------------------------------------------

MAINTENANCE_PARAM = '/cabal/maintenance/imap'
_MAINTENANCE_TTL = 15.0
_DEFAULT_MAINTENANCE_MESSAGE = (
    'Email access is temporarily unavailable due to planned maintenance.'
)
_DEFAULT_RETRY_AFTER = 30
# Per-warm-container cache so per-request SSM traffic stays negligible:
# {'at': monotonic seconds, 'value': parsed dict or None}.
_maintenance_cache = {'at': float('-inf'), 'value': None}


class MaintenanceError(Exception):
    '''Raised by get_imap_client when a planned IMAP roll is in progress.
    maintenance_guard translates it into a 503 maintenance response.'''
    def __init__(self, state):
        self.state = state or {}
        super().__init__('IMAP is in planned maintenance')


class MessageGoneError(Exception):
    '''Raised by get_message when the requested UID is no longer in the folder.
    message_gone_guard translates it into a 404 the clients can act on.'''
    def __init__(self, folder, msg_id):
        self.folder = folder
        self.msg_id = msg_id
        super().__init__(f'no message with UID {msg_id} in {folder}')


def _read_maintenance_param():
    '''Returns the parsed maintenance flag dict, or None. TTL-cached per warm
    container. Fails open to None on any read/parse error.'''
    now = time.monotonic()
    if now - _maintenance_cache['at'] < _MAINTENANCE_TTL:
        return _maintenance_cache['value']
    value = None
    try:
        raw = ssm.get_parameter(Name=MAINTENANCE_PARAM)["Parameter"]["Value"]
        parsed = json.loads(raw)
        if isinstance(parsed, dict):
            value = parsed
    except ssm.exceptions.ParameterNotFound:
        value = None
    except Exception as err:  # pylint: disable=broad-exception-caught
        # Never let a flag-read problem block mail access.
        logging.warning(
            'maintenance flag read failed, assuming not in maintenance: %s', err
        )
        value = None
    _maintenance_cache['at'] = now
    _maintenance_cache['value'] = value
    return value


def maintenance_state():
    '''Returns the active maintenance flag dict when a planned roll is in
    progress and has not expired, else None.'''
    value = _read_maintenance_param()
    if not value or not value.get('active'):
        return None
    until = value.get('until')
    # Backstop: a crashed/cancelled deploy could leave the flag on. Once `until`
    # passes, treat the window as over regardless of `active`.
    if isinstance(until, (int, float)) and not isinstance(until, bool):
        if time.time() > until:
            return None
    return value


def _raise_if_maintenance():
    '''Raises MaintenanceError when a planned IMAP roll is in progress.'''
    state = maintenance_state()
    if state is not None:
        raise MaintenanceError(state)


def maintenance_response(state):
    '''Builds the 503 maintenance proxy response from a flag dict.'''
    state = state or {}
    retry_after = state.get('retry_after', _DEFAULT_RETRY_AFTER)
    try:
        retry_after = int(retry_after)
    except (TypeError, ValueError):
        retry_after = _DEFAULT_RETRY_AFTER
    message = state.get('message') or _DEFAULT_MAINTENANCE_MESSAGE
    return {
        "statusCode": 503,
        "headers": {"Retry-After": str(retry_after)},
        "body": json.dumps({
            "status": "maintenance",
            "message": message,
            "retry_after": retry_after,
        })
    }


def message_gone_response(folder, msg_id):
    '''Builds the 404 served when a requested UID is no longer in the folder.'''
    return {
        "statusCode": 404,
        "body": json.dumps({
            "status": f"That message is no longer in {folder.split('.')[-1]}",
            "folder": folder,
            "id": msg_id,
        })
    }


def message_gone_guard(handler):
    '''Decorator: turns a MessageGoneError raised anywhere inside a handler
    that loads a message body into a 404. Left unhandled it escaped as a
    KeyError, and API Gateway turned that into a bodiless 502 -- clients could
    not tell "this message is gone" (refresh the folder) from "the server is
    broken" (retry later).'''
    @functools.wraps(handler)
    def wrapper(event, context):
        try:
            return handler(event, context)
        except MessageGoneError as err:
            return message_gone_response(err.folder, err.msg_id)
    return wrapper


def maintenance_guard(handler):
    '''Decorator: turns a MaintenanceError raised anywhere inside an IMAP-backed
    handler into a friendly 503 maintenance response so clients can show a
    "temporarily unavailable" message instead of a raw connection error.'''
    @functools.wraps(handler)
    def wrapper(event, context):
        try:
            return handler(event, context)
        except MaintenanceError as err:
            return maintenance_response(err.state)
    return wrapper


def find_managed_apex(domains_map, domain):
    """Returns (apex, zone_id) for the longest managed apex that owns `domain`,
    or (None, None) when `domain` is not managed."""
    domain = (domain or '').lower().rstrip('.')
    best_apex = None
    best_zone = None
    for apex, zone_id in domains_map.items():
        apex_lower = apex.lower()
        if domain == apex_lower or domain.endswith('.' + apex_lower):
            if best_apex is None or len(apex_lower) > len(best_apex):
                best_apex = apex_lower
                best_zone = zone_id
    return (best_apex, best_zone)

def get_imap_client(_host, user, folder, read_only=False):
    '''Returns an IMAP client for the current user with folder selected.

    Raises MaintenanceError when a planned IMAP roll is in progress, so callers
    short-circuit to a friendly 503 (via maintenance_guard) instead of dialing a
    server that is mid-restart. Every IMAP-touching path flows through here, so
    this one check covers reads, folder ops, flags, moves, and cache-miss
    fetches; cache hits never reach this function and keep working.

    Connection handling (including the optional warm-invocation pool) lives in
    imap_session; this wrapper just applies the maintenance gate first, then
    delegates. With pooling off (the default) the returned object is a bare
    IMAPClient connected/authenticated/selected exactly as before.

    The `_host` argument is accepted for call-site compatibility but
    deliberately IGNORED: every IMAP connection authenticates with the shared
    master password, so honoring a client-supplied host would let any
    authenticated caller exfiltrate that credential to a server they control. We
    always dial the environment's canonical IMAP_HOST instead.'''
    if not CONTROL_DOMAIN:
        # Fail loudly, not with a DNS lookup of the garbage name "imap.".
        # CONTROL_DOMAIN's blank import-time default exists for functions that
        # never touch IMAP; a function that reaches this line without it is
        # missing its Terraform environment block (append_sent shipped that
        # way and glibc surfaced it as an inscrutable getaddrinfo EBUSY).
        raise RuntimeError(
            'CONTROL_DOMAIN is not set for this function; cannot derive '
            "IMAP_HOST. Add it to the function's Terraform environment block."
        )
    _raise_if_maintenance()
    return open_imap_client(IMAP_HOST, user, folder, read_only, mpw)


def address_row_for_sender(user, sender):
    """Fetches the stored cabal-addresses row for `sender` and reports whether
    the user may send from it, as (item, authorized).

    `item` is the stored row, or {} when the address has no row or the lookup
    failed, so a caller that also needs the row does not have to read it a
    second time. A lookup failure is reported as unauthorized rather than
    raised, so the caller answers 403 instead of relaying a traceback.

    The row's `user` attribute is slash-delimited: assign_address joins every
    assignee into one string, so a co-assigned address stores "alice/bob".
    Membership, not equality, is the ownership test -- an `==` here answers
    False for every assignee of a multi-user address, the original owner
    included, while /list and set_favorite (which already split) keep showing
    it to all of them.
    """
    try:
        response = ddb_table.get_item(Key={'address': sender})
    except ClientError as err:
        print(err.response['Error']['Message'])
        return {}, False
    item = response.get('Item') or {}
    assigned = (item.get('user') or '').split('/')
    return item, user in assigned


def user_authorized_for_sender(user, sender):
    """Checks whether the user is allowed to send from the specifed sender address"""
    _, authorized = address_row_for_sender(user, sender)
    return authorized


def authorized_address_request(event):
    """Parses an address-scoped request body and authorizes the caller against
    the stored row, returning (address, item, error).

    On success `error` is None, `address` is the requested address and `item`
    is that address's stored cabal-addresses row. On a malformed body, or an
    address the caller does not own, `error` is a ready-to-return response and
    the other two are None, so a handler can `return error`. Shared by the
    address-lifecycle endpoints (revoke, suspend, reinstate) so all three gate
    on the same check with the same wire shape, and so the stored row each of
    them goes on to read costs one DynamoDB lookup rather than two.
    """
    body, error = parse_json_body(event)
    if error:
        return None, None, error
    address = body['address']
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    item, authorized = address_row_for_sender(user, address)
    if not authorized:
        return None, None, {
            'statusCode': 403,
            'body': json.dumps({
                'Error': 'Address not associated with authenticated user'
            })
        }
    return address, item, None


def user_authorized_for_domain(user, domain):
    """Checks whether the user is permitted to create addresses on the given
    apex domain. The cabal-user-domain-access table is an allow list: a row
    keyed on (user, domain) means the user IS permitted. Missing row = deny.
    On lookup failure, default to deny so a transient DynamoDB error cannot
    silently grant access (and matches the default-deny policy of the table)."""
    try:
        response = user_domain_access_table.get_item(
            Key={'user': user, 'domain': domain}
        )
    except ClientError as err:
        print(err.response['Error']['Message'])
        return False
    return 'Item' in response


MAX_IDS_PER_REQUEST = 5000
MAX_IDS_PER_IMAP_CMD = 500
MAX_FOLDER_NAME_BYTES = 255
MAX_KEYWORD_LEN = 64
MAX_CONTENT_ID_LEN = 128
# RFC 5322's line limit; a Message-ID header can legally run right up to it.
MAX_MESSAGE_ID_LEN = 998
MAX_SEARCH_TEXT_LEN = 1024
MAX_UID = 0xFFFFFFFF
MAX_PAGE_SIZE = 250

_FOLDER_NAME_RE = re.compile(r'^[A-Za-z0-9 _\-./]+$')
_KEYWORD_RE = re.compile(r'^[A-Za-z0-9_\-]+$')
_CONTROL_CHARS_RE = re.compile(r'[\x00-\x1f\x7f]')
_CONTENT_ID_FORBIDDEN_RE = re.compile(r'[\x00-\x1f\x7f\s/\\]')
_MESSAGE_ID_FORBIDDEN_RE = re.compile(r'[\x00-\x1f\x7f\s]')
_ATTACHMENT_NAME_FORBIDDEN_RE = re.compile(r'[\x00-\x1f\x7f/\\]')

# Lowercased wire form -> canonical form. Only these five system flags are
# client-settable; \Recent and friends are server-managed and never accepted.
_SYSTEM_FLAGS = {
    r'\seen': r'\Seen',
    r'\answered': r'\Answered',
    r'\flagged': r'\Flagged',
    r'\deleted': r'\Deleted',
    r'\draft': r'\Draft',
}

# RFC 5256 SORT keys we expose. ASC maps to no prefix, DESC to REVERSE.
_SORT_FIELDS = {'ARRIVAL', 'CC', 'DATE', 'FROM', 'SIZE', 'SUBJECT', 'TO'}

# Folder names the destructive endpoints (purge_messages, empty_trash)
# may operate on, so a client bug can never expunge a non-trash folder.
# Every client files deletions in Dovecot's special-use \Trash mailbox
# ("Trash"). Legacy "Deleted Messages" folders (the web client's
# pre-Trash delete target) are ordinary folders and deliberately not
# purgeable; they are emptied by deleting the folder itself.
TRASH_FOLDERS = ('Trash',)


def validate_folder_name(name):
    '''Validates a `/`-separated display folder name and returns it unchanged.

    Case-preserving; allows letters, digits, space, and `_ - . /`. Rejects
    empty and anything over 255 bytes. ASCII-only by design: the system's
    folders (INBOX, Archive, Sent Messages, ...) are ASCII, so a non-ASCII
    name is rejected rather than round-tripped through modified UTF-7.
    '''
    if not isinstance(name, str) or not name:
        raise ValueError('folder name is required')
    if len(name.encode('utf-8')) > MAX_FOLDER_NAME_BYTES:
        raise ValueError('folder name is too long')
    if not _FOLDER_NAME_RE.match(name):
        raise ValueError(f'invalid folder name: {name!r}')
    # The regex permits `.` and `/`, so reject the segments that would turn a
    # folder name into a traversal-shaped S3 key fragment (fetch_inline_image
    # embeds the folder in a key) or an empty IMAP hierarchy component. No real
    # folder is named `.`/`..` or has an empty (`//`, leading/trailing `/`)
    # segment.
    if any(seg in ('', '.', '..') for seg in name.split('/')):
        raise ValueError(f'invalid folder name: {name!r}')
    return name


def validate_trash_folder(name):
    '''Validates a folder name and additionally requires it to be one of the
    known trash folders (TRASH_FOLDERS). Raises ValueError otherwise.'''
    name = validate_folder_name(name)
    if name not in TRASH_FOLDERS:
        raise ValueError(f'not a trash folder: {name!r}')
    return name


def validate_uid_list(ids):
    '''Validates a list of IMAP UIDs, returning a list[int] in [1, 2**32-1].

    Accepts ints or numeric strings (JSON bodies and query strings both occur).
    Caps length at MAX_IDS_PER_REQUEST. Booleans are rejected (Python treats
    them as ints, which would silently coerce True -> UID 1).
    '''
    if not isinstance(ids, (list, tuple)):
        raise ValueError('ids must be a list')
    if len(ids) > MAX_IDS_PER_REQUEST:
        raise ValueError(f'too many ids (max {MAX_IDS_PER_REQUEST})')
    out = []
    for raw in ids:
        if isinstance(raw, bool):
            raise ValueError(f'invalid message id: {raw!r}')
        try:
            num = int(raw)
        except (TypeError, ValueError) as exc:
            raise ValueError(f'invalid message id: {raw!r}') from exc
        if num < 1 or num > MAX_UID:
            raise ValueError(f'message id out of range: {num}')
        out.append(num)
    return out


def validate_uid(value):
    '''Validates a single IMAP UID, returning an int in [1, 2**32-1].'''
    return validate_uid_list([value])[0]


def validate_pagination(offset, limit):
    '''Validates the optional `offset`/`limit` list-pagination query params.

    Returns (offset:int>=0, limit:int>0 or None). A missing or empty value
    means "no bound": offset defaults to 0 and a missing limit returns None, so
    the caller serves the full list and the pre-pagination contract is kept.
    An explicit limit above MAX_PAGE_SIZE is clamped to it (the page stays
    "within reason") rather than rejected. Raises ValueError on non-numeric or
    out-of-range input.
    '''
    parsed_offset = 0
    if offset not in (None, ''):
        try:
            parsed_offset = int(offset)
        except (TypeError, ValueError) as exc:
            raise ValueError(f'invalid offset: {offset!r}') from exc
        if parsed_offset < 0:
            raise ValueError(f'offset out of range: {parsed_offset}')
    parsed_limit = None
    if limit not in (None, ''):
        try:
            parsed_limit = int(limit)
        except (TypeError, ValueError) as exc:
            raise ValueError(f'invalid limit: {limit!r}') from exc
        if parsed_limit < 1:
            raise ValueError(f'limit out of range: {parsed_limit}')
        # Clamp rather than reject: offset pagination is transparent to a
        # smaller-than-requested page, so a client asking for too much simply
        # gets the maximum reasonable page instead of an error.
        parsed_limit = min(parsed_limit, MAX_PAGE_SIZE)
    return parsed_offset, parsed_limit


def apply_in_batches(ids, operation):
    '''Runs `operation(batch)` over MAX_IDS_PER_IMAP_CMD-sized slices of `ids`,
    returning (succeeded_ids, failed_ids).

    Bulk UID MOVE / UID STORE are issued in bounded batches so no single IMAP
    command blocks the Lambda long enough to brush the 29s API Gateway ceiling
    on a large selection. A batch whose operation raises is recorded as failed
    and the run continues; the batches are independent UID sets, so the split
    is accurate and a client can retry only the failed ids.
    '''
    succeeded = []
    failed = []
    for start in range(0, len(ids), MAX_IDS_PER_IMAP_CMD):
        batch = ids[start:start + MAX_IDS_PER_IMAP_CMD]
        try:
            operation(batch)
            succeeded.extend(batch)
        except Exception:  # pylint: disable=broad-except
            failed.extend(batch)
    return succeeded, failed


def too_many_ids_response():
    '''413 the bulk endpoints return when an id list exceeds MAX_IDS_PER_REQUEST,
    carrying the cap so a client can split the request and retry.'''
    return {
        "statusCode": 413,
        "body": json.dumps({"max_ids": MAX_IDS_PER_REQUEST})
    }


def parse_json_body(event):
    '''Parses the request body as a JSON object, returning (body, error).

    On success `error` is None and `body` is the decoded dict. On a missing,
    empty, or non-JSON body -- or one that decodes to something other than a
    JSON object -- `error` is a ready-to-return 400 response and `body` is None,
    so a handler can `return error` instead of relaying an unhandled 500/502
    with a Python traceback. Mirrors parse_bulk_request's contract and 400 shape
    so every handler that needs a JSON object body rejects a bad one the same
    way.
    '''
    raw = event.get('body')
    if not raw:
        message = 'request body is required'
    else:
        try:
            body = json.loads(raw)
        except (TypeError, json.JSONDecodeError):
            message = 'request body is not valid JSON'
        else:
            if isinstance(body, dict):
                return body, None
            message = 'request body must be a JSON object'
    return None, {
        "statusCode": 400,
        "body": json.dumps({"status": f"Invalid input: {message}"})
    }


def parse_bulk_request(event):
    '''Parses a bulk-op request body and enforces the per-request id cap.

    Returns (body, error). On success `error` is None; on a malformed body or an
    oversized id list, `error` is a ready-to-return 400/413 response and `body`
    is None. The caller still validates the folder/flag/uid contents.
    '''
    try:
        body = json.loads(event['body'])
    except (TypeError, json.JSONDecodeError):
        return None, {
            "statusCode": 400,
            "body": json.dumps(
                {"status": "Invalid input: request body is not valid JSON"})
        }
    raw_ids = body.get('ids')
    if isinstance(raw_ids, (list, tuple)) and len(raw_ids) > MAX_IDS_PER_REQUEST:
        return None, too_many_ids_response()
    return body, None


def batch_result_response(succeeded, failed, succeeded_key):
    '''Builds the response for a batched bulk op: 500 when nothing succeeded,
    200 "partial" with the succeeded/failed split when some batches failed, else
    200 "submitted". `succeeded_key` names the success list in the partial body
    (e.g. "moved_ids" / "flagged_ids").'''
    if not succeeded:
        return {
            "statusCode": 500,
            "body": json.dumps({"status": "unable"})
        }
    if failed:
        return {
            "statusCode": 200,
            "body": json.dumps({
                "status": "partial",
                succeeded_key: succeeded,
                "failed_ids": failed
            })
        }
    return {
        "statusCode": 200,
        "body": json.dumps({"status": "submitted"})
    }


def validate_flag(flag):
    '''Validates an IMAP flag, returning a canonical system flag or a safe
    custom keyword (`^[A-Za-z0-9_-]+$`, <= 64 chars). Raises ValueError else.'''
    if not isinstance(flag, str) or not flag:
        raise ValueError('flag is required')
    canonical = _SYSTEM_FLAGS.get(flag.lower())
    if canonical:
        return canonical
    if flag.startswith('\\'):
        raise ValueError(f'unknown system flag: {flag!r}')
    if len(flag) > MAX_KEYWORD_LEN or not _KEYWORD_RE.match(flag):
        raise ValueError(f'invalid flag: {flag!r}')
    return flag


def validate_sort_criterion(sort_order, sort_field):
    '''Validates the sort wire pair, returning a safe IMAP SORT criterion.

    Clients send `sort_order` as the IMAP-native `"REVERSE "` (descending) or
    `""` (ascending) and `sort_field` as a bare RFC 5256 key. Returns the
    assembled criterion (e.g. `"REVERSE ARRIVAL"`) ready for IMAPClient.sort().
    '''
    if not isinstance(sort_field, str):
        raise ValueError('sort_field is required')
    field = sort_field.strip().upper()
    if field not in _SORT_FIELDS:
        raise ValueError(f'invalid sort field: {sort_field!r}')
    order = (sort_order or '').strip().upper()
    if order not in ('', 'REVERSE'):
        raise ValueError(f'invalid sort order: {sort_order!r}')
    return f'{order} {field}'.strip()


def validate_content_id(value):
    '''Validates an inline-image Content-ID as the clients send it: a bracketed
    `<id-left@id-right>` token (see ApiClient.js `fetchImage`). Permits the
    message-id character set plus the angle brackets and rejects path
    separators, whitespace, and control bytes, so it is safe to embed in an
    S3 key. Returns the value unchanged.

    This realizes the plan's `validate_safe_path_component` for `index`: the
    plan's literal `^[A-Za-z0-9_.@-]+$` would reject the angle brackets every
    real Content-ID carries, so the check is widened to the bracket form and
    tightened to a deny-list of the genuinely dangerous bytes.
    '''
    if not isinstance(value, str) or not value:
        raise ValueError('content-id is required')
    if len(value) > MAX_CONTENT_ID_LEN:
        raise ValueError('content-id is too long')
    if not (value.startswith('<') and value.endswith('>') and len(value) >= 3):
        raise ValueError('content-id must be a bracketed token')
    if _CONTENT_ID_FORBIDDEN_RE.search(value):
        raise ValueError('content-id contains illegal characters')
    return value


def validate_message_id(value):
    '''Validates an RFC 5322 Message-ID as the push wake signals carry it: a
    bracketed `<id-left@id-right>` token. Unlike validate_content_id this
    permits path separators: GitHub notification Message-IDs contain `/`
    (`<owner/repo/pull/123/...@github.com>`), and the value is only ever an
    IMAP SEARCH argument, never embedded in an S3 key -- rejecting the slash
    silently downgraded every GitHub message to hint-only UID resolution,
    which mis-targets enrichment whenever a delivery burst reuses one stale
    next-uid hint. Control bytes and whitespace stay rejected, and the cap is
    the RFC 5322 line limit rather than the Content-ID cap real Message-IDs
    exceed. Returns the value unchanged.'''
    if not isinstance(value, str) or not value:
        raise ValueError('message-id is required')
    if len(value) > MAX_MESSAGE_ID_LEN:
        raise ValueError('message-id is too long')
    if not (value.startswith('<') and value.endswith('>') and len(value) >= 3):
        raise ValueError('message-id must be a bracketed token')
    if _MESSAGE_ID_FORBIDDEN_RE.search(value):
        raise ValueError('message-id contains illegal characters')
    return value


def validate_part_index(value):
    '''Validates a MIME part serial number, returning an int >= 0.

    A part index is a position in `message.walk()`, not a UID: part 0 is the
    message itself and is a legal value, so validate_uid's [1, 2**32-1] range
    doesn't apply. Booleans are rejected for the same reason as in
    validate_uid_list.
    '''
    if isinstance(value, bool):
        raise ValueError(f'invalid attachment index: {value!r}')
    try:
        index = int(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f'invalid attachment index: {value!r}') from exc
    if index < 0:
        raise ValueError(f'attachment index out of range: {index}')
    return index


def validate_attachment_filename(value):
    '''Validates the filename an attachment is cached under, returning it
    unchanged.

    The value becomes the last component of an S3 key, so path separators,
    control bytes, and the traversal names are rejected. Otherwise it stays
    permissive: this is a real MIME filename taken from the message, and
    spaces, non-ASCII, and punctuation all occur in the wild.
    '''
    if not isinstance(value, str) or not value:
        raise ValueError('filename is required')
    if len(value.encode('utf-8')) > MAX_FOLDER_NAME_BYTES:
        raise ValueError('filename is too long')
    if _ATTACHMENT_NAME_FORBIDDEN_RE.search(value):
        raise ValueError('filename contains illegal characters')
    if value in ('.', '..'):
        raise ValueError(f'invalid filename: {value!r}')
    return value


def validate_search_text(value):
    '''Bounds one structured-search free-text field (text/from/to/subject).

    These reach IMAP SEARCH as discrete quoted arguments, so imapclient handles
    escaping; this only caps length and rejects control bytes (NUL and friends
    have no place in a search term and can confuse the protocol). `None` passes
    through so callers can validate optional fields uniformly.
    '''
    if value is None:
        return value
    if not isinstance(value, str):
        raise ValueError('search term must be a string')
    if len(value) > MAX_SEARCH_TEXT_LEN:
        raise ValueError('search term is too long')
    if _CONTROL_CHARS_RE.search(value):
        raise ValueError('search term contains control characters')
    return value


# ---------------------------------------------------------------------------
# DNS validators and runtime zone verification (Phase 4 of the same plan).
#
# The DNS-touching handlers compose Route 53 record names and dns.resolver
# queries from request-body subdomains and apexes. Validate the shape so a
# hostile value cannot deform a change batch, and -- before any write --
# re-verify at runtime that the zone id the DOMAINS env var maps an apex to
# actually owns that apex, so a drifted env var (operator typo, half-applied
# Terraform, region mismatch) cannot push changes into the wrong zone.
# ---------------------------------------------------------------------------

MAX_DNS_NAME_LEN = 253
_DNS_LABEL_RE = re.compile(r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$', re.IGNORECASE)

_zone_cache = {}
_R53_CLIENT = None


def validate_dns_label(label):
    '''Validates a single DNS label (RFC 1035 preferred form, case-insensitive).
    Returns it unchanged. Raises ValueError otherwise.'''
    if not isinstance(label, str) or not label:
        raise ValueError('dns label is required')
    if not _DNS_LABEL_RE.match(label):
        raise ValueError(f'invalid dns label: {label!r}')
    return label


def _validate_dns_name(name, min_labels, what):
    '''Validates a dotted DNS name of at least min_labels labels, each a valid
    DNS label, total <= 253 bytes. Returns `name` unchanged so the caller's
    stored / record values and DOMAINS-dict lookups are never mutated.'''
    if not isinstance(name, str) or not name:
        raise ValueError(f'{what} is required')
    cleaned = name.rstrip('.')
    if not cleaned or len(cleaned) > MAX_DNS_NAME_LEN:
        raise ValueError(f'invalid {what}: {name!r}')
    labels = cleaned.split('.')
    if len(labels) < min_labels:
        raise ValueError(f'{what} must have at least {min_labels} label(s): {name!r}')
    for label in labels:
        if not _DNS_LABEL_RE.match(label):
            raise ValueError(f'invalid {what}: {name!r}')
    return name


def validate_dns_apex(domain):
    '''Validates an apex or managed subdomain: >= 2 dot-separated DNS labels.
    Returns the value unchanged. Raises ValueError otherwise.'''
    return _validate_dns_name(domain, 2, 'domain')


def validate_dns_subdomain(subdomain):
    '''Validates a per-address subdomain: >= 1 dot-separated DNS label.

    The UI's subdomain field is conceptually single-label, but it is free text
    and has historically accepted dotted multi-label values, so this stays at
    >= 1 label (rather than the plan's single-label validate_dns_label) to keep
    revoke working for any pre-existing address. Returns the value unchanged.
    '''
    return _validate_dns_name(subdomain, 1, 'subdomain')


def validate_local_part(local):
    '''Validates an address local part (the text before the @): rejects an empty
    value or any embedded whitespace, then returns it unchanged. Whitespace is
    the guard that matters -- the local part is written verbatim into the
    sendmail virtusertable, where makemap rejects a leading space and treats a
    tab as the key/value separator, so either wedges the map rebuild for a whole
    tier and crash-loops the reconfigure sidecar (see generate-config.sh).'''
    if not isinstance(local, str) or not local:
        raise ValueError('username is required')
    if any(ch.isspace() for ch in local):
        raise ValueError(f'username must not contain whitespace: {local!r}')
    return local


class ZoneMismatchError(Exception):
    '''Raised when a hosted-zone id does not actually own the apex the DOMAINS
    env var maps it to. Signals operator/Terraform drift, not user error.'''


# Subdomains reserved on the control domain. When the control domain doubles as
# a mail domain (it appears in mail_domains), these labels already carry
# infrastructure records in the control zone: CloudFront/NLB aliases (admin,
# www, imap, smtp, smtp-in, smtp-out), the system mail user (mail-admin), and
# the DKIM/DMARC selectors (cabal._domainkey, _dmarc). An address record at one
# of these names would either fail (Route 53 rejects an MX/TXT alongside an
# existing CNAME) or clobber an auth record (an SPF TXT UPSERT would overwrite
# the apex DKIM/DMARC TXT). These collisions only exist on the control domain;
# dedicated mail domains have no such records, so the guard is scoped to it.
RESERVED_CONTROL_SUBDOMAINS = frozenset({
    'admin', 'www', 'imap', 'smtp', 'smtp-in', 'smtp-out', 'mail-admin',
    'cabal._domainkey', '_dmarc',
})

# Subdomains reserved on every domain, control or mail. `mail-admin` is the
# system sender's own label: modules/app/dmarc_user.tf provisions it on
# domains[0] - the first *mail* domain, not the control domain - with a full
# MX/SPF/DKIM/DMARC/BIMI set, and CLAUDE.md names mail-admin.<first mail
# domain> as the identity for all system-originated mail. A user address there
# is not a clobber (the records address_dns_records() writes are byte-identical
# to Terraform's, and revoke cannot delete them while the system rows hold the
# subdomain), but its holder can send mail that DKIM-signs d=mail-admin.<first
# mail domain> and SPF-aligns exactly like a real notification, which a
# receiver cannot tell apart (#1097). Reserved on every domain rather than only
# domains[0] because that index moves when TF_VAR_MAIL_DOMAINS is reordered,
# which would hand the system identity to an existing squatter.
RESERVED_SUBDOMAINS_EVERY_DOMAIN = frozenset({'mail-admin'})


def reserved_subdomain_response_or_none(subdomain, tld, control_domain):
    '''Returns a 400 response when `subdomain` is reserved - on every domain
    for RESERVED_SUBDOMAINS_EVERY_DOMAIN, on the control domain only for
    RESERVED_CONTROL_SUBDOMAINS - else None. Shared rather than owned by one
    handler so every path that publishes address DNS applies the same guard:
    the admin create path reached the identical UPSERT with no check at all
    (#1072).'''
    label = str(subdomain).lower().rstrip('.')
    if label in RESERVED_SUBDOMAINS_EVERY_DOMAIN:
        return _reserved_response(subdomain, 'reserved on every mail domain')
    if tld == control_domain and label in RESERVED_CONTROL_SUBDOMAINS:
        return _reserved_response(
            subdomain, f'reserved on the control domain "{control_domain}"')
    return None


def _reserved_response(subdomain, scope):
    '''Builds the 400 a reserved-label create is refused with.'''
    return {
        'statusCode': 400,
        'body': json.dumps({
            'Error': f'Subdomain "{subdomain}" is {scope}'
        })
    }


def new_address_response_or_none(body, domains, control_domain):
    '''Vets the address a create request asks for -- known domain, valid DNS
    labels and local part, subdomain not reserved -- and returns the 400 to
    send back, or None when the request may proceed.

    Shared by the two create endpoints (`new` and `new_address_admin`) for the
    same reason publish_address_dns_records is: they must accept exactly the
    same set of addresses, and the admin copy of these guards is the one that
    went missing (#1072). Everything past this point differs between them --
    who the address is recorded for, and which authorization the caller needs.
    '''
    if body['tld'] not in domains:
        return {
            'statusCode': 400,
            'body': json.dumps({'Error': f"Unknown domain \"{body['tld']}\""})
        }
    try:
        validate_dns_apex(body['tld'])
        validate_dns_subdomain(body['subdomain'])
        validate_local_part(body['username'])
    except ValueError as err:
        return {
            'statusCode': 400,
            'body': json.dumps({'Error': f'Invalid input: {err}'})
        }
    return reserved_subdomain_response_or_none(
        body['subdomain'], body['tld'], control_domain)


def _route53():
    '''Lazily builds the shared Route 53 client (only the DNS handlers need it,
    so non-DNS lambdas importing helper never pay for it).'''
    global _R53_CLIENT  # pylint: disable=global-statement
    if _R53_CLIENT is None:
        _R53_CLIENT = boto3.client('route53')
    return _R53_CLIENT


def assert_zone_owns_apex(zone_id, apex):
    '''Best-effort runtime guard that hosted zone `zone_id` actually owns `apex`
    before a change_resource_record_sets call. The zone Name is cached per cold
    start so warm invocations skip the get_hosted_zone round-trip.

    Fails CLOSED on a positive mismatch: raises ZoneMismatchError so the caller
    returns 500, after emitting a WARN log line for alerting. Fails OPEN when
    the zone simply cannot be looked up (e.g. the route53:GetHostedZone grant
    has not propagated yet, or a transient API error): it logs and returns so
    the request proceeds exactly as it did before this guard existed, and the
    failure mode is never "address management is wedged."
    '''
    expected = apex.rstrip('.').lower() + '.'
    name = _zone_cache.get(zone_id)
    if name is None:
        try:
            resp = _route53().get_hosted_zone(Id=zone_id)
        except Exception as err:  # pylint: disable=broad-exception-caught
            print(f'[zone-verify] WARN could not verify zone {zone_id!r} owns '
                  f'{apex!r}, proceeding: {err}')
            return
        name = resp['HostedZone']['Name'].lower()
        _zone_cache[zone_id] = name
    if name != expected:
        print(f'[zone-verify] WARN zone-mismatch: zone {zone_id!r} resolves to '
              f'{name!r}, expected {expected!r} (apex {apex!r})')
        raise ZoneMismatchError(f'zone-mismatch: zone {zone_id} does not own {apex}')


def address_dns_records(subdomain, tld, control_domain):
    '''Canonical DNS record set for an address subdomain, as (name, type, value)
    tuples. Every path that publishes address DNS goes through this set -- the
    `new` and `new_address_admin` create paths via publish_address_dns_records,
    reinstate the same way, suspend/revoke deleting exactly these names. A
    handler keeping its own copy of the list is how the admin path came to
    publish four of the five (#1073).'''
    return (
        (f'{subdomain}.{tld}', 'MX', f'10 smtp-in.{control_domain}'),
        (f'{subdomain}.{tld}', 'TXT', f'"v=spf1 include:{control_domain} ~all"'),
        (f'cabal._domainkey.{subdomain}.{tld}', 'CNAME',
         f'cabal._domainkey.{control_domain}'),
        (f'_dmarc.{subdomain}.{tld}', 'CNAME', f'_dmarc.{control_domain}'),
        # BIMI: publish the Cabalmail mark for mail sent from this subdomain.
        # The lookup name (default._bimi.<subdomain>.<tld>) has the per-address
        # subdomain in the middle, so it cannot be served by a DNS wildcard (a
        # wildcard only matches a leftmost label) - same reason _dmarc and
        # _domainkey are written per address. Points at the SVG; receivers
        # rasterize it.
        (f'default._bimi.{subdomain}.{tld}', 'TXT',
         f'"v=BIMI1; l=https://www.{control_domain}/assets/bimi/cabalmail.svg"'),
    )


def _find_rrset(zone_id, name, rtype):
    '''Returns the live resource record set at (name, rtype) in the zone, or
    None if absent. Exact-match on name and type; Route 53 returns names with a
    trailing dot.'''
    resp = _route53().list_resource_record_sets(
        HostedZoneId=zone_id,
        StartRecordName=name,
        StartRecordType=rtype,
        MaxItems='1'
    )
    for rrset in resp.get('ResourceRecordSets', []):
        if rrset['Name'].rstrip('.').lower() == name.rstrip('.').lower() \
                and rrset['Type'] == rtype:
            return rrset
    return None


def publish_address_dns_records(zone_id, subdomain, tld, control_domain):
    '''UPSERTs the canonical DNS record set for an address subdomain.'''
    assert_zone_owns_apex(zone_id, tld)
    changes = [{
        'Action': 'UPSERT',
        'ResourceRecordSet': {
            'Name': name,
            'Type': rtype,
            'TTL': 3600,
            'ResourceRecords': [{'Value': value}]
        }
    } for name, rtype, value in address_dns_records(subdomain, tld, control_domain)]
    _route53().change_resource_record_sets(
        HostedZoneId=zone_id, ChangeBatch={'Changes': changes})


def delete_address_dns_records(zone_id, subdomain, tld, control_domain):
    '''Deletes the canonical DNS record set for an address subdomain. Deletes
    are built from the records actually live in the zone rather than blind
    expected values, so a partially absent set (an address predating the BIMI
    record, or a re-run after an earlier partial delete) cannot fail the whole
    change batch with InvalidChangeBatch.'''
    assert_zone_owns_apex(zone_id, tld)
    changes = []
    for name, rtype, _value in address_dns_records(subdomain, tld, control_domain):
        rrset = _find_rrset(zone_id, name, rtype)
        if rrset:
            changes.append({'Action': 'DELETE', 'ResourceRecordSet': rrset})
    if changes:
        _route53().change_resource_record_sets(
            HostedZoneId=zone_id, ChangeBatch={'Changes': changes})


def active_addresses_on_subdomain(subdomain, tld, address):
    '''Checks if other non-suspended addresses share the same subdomain and TLD.
    The DNS records of a subdomain are shared by every address on it, so
    suspend/revoke only delete them once this returns False. Suspended
    co-tenants do not count: their contract is already "DNS absent", and
    reinstate republishes the records if one comes back.'''
    scan_kwargs = {
        'FilterExpression': (
            'subdomain = :sub AND tld = :tld AND address <> :addr '
            'AND (attribute_not_exists(#s) OR #s = :false)'
        ),
        'ExpressionAttributeNames': {'#s': 'suspended'},
        'ExpressionAttributeValues': {
            ':sub': subdomain,
            ':tld': tld,
            ':addr': address,
            ':false': False
        },
        'ProjectionExpression': 'address'
    }
    while True:
        response = ddb_table.scan(**scan_kwargs)
        if response.get('Items'):
            return True
        if 'LastEvaluatedKey' not in response:
            break
        scan_kwargs['ExclusiveStartKey'] = response['LastEvaluatedKey']
    return False


def teardown_address_dns_if_unused(item, address, domains_map, control_domain):
    '''Removes an address subdomain's DNS record set when no other ACTIVE
    (non-suspended) address still needs it. The one copy of the teardown
    gate shared by revoke, suspend_address, and reap_pending_addresses, so
    the three paths cannot drift the way the create paths once did (#1073).

    subdomain/tld are taken from the STORED row (`item`), never from any
    request body: callers authorize on `address` only, so honoring a
    client-supplied subdomain/tld would let a caller who owns any one
    address delete another user's DNS records. The zone is resolved from
    DOMAINS, never from a zone-id cached on the row: that value is a
    creation-time snapshot that goes stale if a hosted zone is recreated
    (legacy rows pointed at zones that no longer exist, failing Route 53
    calls with NoSuchHostedZone). For a tld no longer in DOMAINS this
    resolves to None and the DNS step is skipped -- the Lambda role's
    Route 53 grant only covers managed zones anyway. Pending (unconfirmed)
    co-tenants DO keep the records alive: a pending address must be able
    to receive its verification mail, which is the whole point of the
    eager-create model (docs/1.x/browser-extension-plan.md).'''
    subdomain = item.get('subdomain')
    tld = item.get('tld')
    zone_id = domains_map.get(tld)
    if subdomain and tld and zone_id and \
            not active_addresses_on_subdomain(subdomain, tld, address):
        delete_address_dns_records(zone_id, subdomain, tld, control_domain)


REPORT_PAGE_LIMIT = 50


def paged_report_response(event, table, sort_key, project):
    '''Returns one reverse-chronological page of records from a report table as
    a complete handler response.

    Reads the opaque `next_token` query parameter (base64 of the DynamoDB
    ExclusiveStartKey), scans one page, sorts it descending on `sort_key` --
    within the page only, which is what a scan of an unordered table can offer
    -- and maps each item through `project` to build the `Reports` list. A
    further page is advertised as `NextToken`. Any failure, including one raised
    by `project`, becomes a 500 carrying the exception text.'''
    try:
        params = event.get('queryStringParameters') or {}
        scan_kwargs = {
            'Limit': REPORT_PAGE_LIMIT
        }

        next_token = params.get('next_token', '')
        if next_token:
            scan_kwargs['ExclusiveStartKey'] = json.loads(
                base64.b64decode(next_token).decode('utf-8')
            )

        response = table.scan(**scan_kwargs)
        items = response.get('Items', [])

        items.sort(key=lambda x: x.get(sort_key, '0'), reverse=True)

        result = {'Reports': [project(item) for item in items]}

        last_key = response.get('LastEvaluatedKey')
        if last_key:
            result['NextToken'] = base64.b64encode(
                json.dumps(last_key).encode('utf-8')
            ).decode('utf-8')

    except Exception as err:  # pylint: disable=broad-exception-caught
        return {
            'statusCode': 500,
            'body': json.dumps({'Error': str(err)})
        }
    return {
        'statusCode': 200,
        'body': json.dumps(result)
    }


# Folder-size observability (Layer 4.1 of the large-mailbox hardening plan).
# Each list handler emits one key=value log line tagging the request with a
# coarse folder-size bucket so CloudWatch Logs Insights can correlate request
# latency with mailbox cardinality -- no Terraform or custom metrics. The bucket
# boundaries and the `folder_size_bucket` dimension name match the plan. Only
# the folder name and bucket are logged, so no PII beyond the existing lines.

# (exclusive upper bound, label); a count at or above the last bound is `>100k`.
_FOLDER_SIZE_BUCKETS = ((1000, '<1k'), (10000, '1k-10k'), (100000, '10k-100k'))


def folder_size_bucket(total):
    '''Coarse size-bucket label for a folder message count. Returns `unknown`
    when the count is missing (None/non-int/negative) so a missing total never
    masks the rest of the log line.'''
    if not isinstance(total, int) or isinstance(total, bool) or total < 0:
        return 'unknown'
    for upper, label in _FOLDER_SIZE_BUCKETS:
        if total < upper:
            return label
    return '>100k'


def folder_message_count(client, folder):
    '''Best-effort STATUS read of a folder's message count, for size-bucket
    logging only. Returns the count, or None on failure -- it feeds coarse
    observability, so it must never disturb a request that already succeeded.'''
    try:
        return client.folder_status(folder, [b'MESSAGES']).get(b'MESSAGES')
    except Exception:  # pylint: disable=broad-exception-caught
        return None


def log_folder_size_bucket(folder, total, endpoint, duration_ms):
    '''Emits one key=value folder-size line for CloudWatch Insights
    latency-vs-size correlation (Layer 4.1). Best-effort. The folder name is
    quoted and last (it may contain spaces) so the leading pairs parse clean.'''
    try:
        print(f'[folder-size] endpoint={endpoint} '
              f'folder_size_bucket={folder_size_bucket(total)} '
              f'messages={total} duration_ms={duration_ms} folder={folder!r}')
    except Exception:  # pylint: disable=broad-exception-caught
        pass


def get_folder_list(client):
    '''
    Retrieves IMAP folders returning separate lists for all folders
    and subscribed folders
    '''
    all_folders = client.list_folders()
    sub_folders = client.list_sub_folders()
    return {
      'folders': decode_folder_list(all_folders),
      'sub_folders': decode_folder_list(sub_folders)
    }

def decode_folder_list(data):
    '''Converts folder list to simple list'''
    folders = []
    for m in data:
        folders.append(m[2].replace(".","/"))
    return sorted(folders, key=folder_sort)

def folder_sort(k):
    '''Sort key that pins INBOX first and case-folds the rest.'''
    if k == 'INBOX':
        return k
    return k.lower()

def subscribe_folder(folder, host, user):
    '''Subscribes the user to an IMAP folder.'''
    client = get_imap_client(host, user, folder)
    return_value = client.subscribe_folder(folder)
    client.logout()
    return return_value

def unsubscribe_folder(folder, host, user):
    '''Unsubscribes the user from an IMAP folder.

    Selects INBOX rather than the target folder: UNSUBSCRIBE does not require
    the mailbox to be selected, and it must keep working after the mailbox is
    deleted -- Dovecot keeps LSUB entries for deleted mailboxes, and clearing
    such an entry is the only way to stop the folder haunting clients'
    Subscribed list.'''
    client = get_imap_client(host, user, 'INBOX')
    return_value = client.unsubscribe_folder(folder)
    client.logout()
    return return_value

def get_message(_host, user, folder, msg_id):
    '''Gets a message from cache on s3 or from imap server.

    `_host` is ignored (see get_imap_client); the cache bucket and IMAP target
    are derived from the environment, never from the request.

    Empty raw bytes are never message content: a local delivery interrupted
    mid-write (the reconfigure loop's sendmail restart) can leave a zero-byte
    message file, which Dovecot serves as an empty RFC822 literal and
    email.message_from_bytes parses into a message with no headers at all --
    push enrichment then renders a blank alert, and once cached the message
    body opens blank forever. An empty fetch is therefore the message being
    gone, and an empty cache entry (written before this guard existed) is
    deleted and refetched instead of served.'''
    bucket = CACHE_BUCKET
    email_body_raw = b''
    key = f"{user}/{folder}/{msg_id}/raw"
    if key_exists(bucket, key):
        email_body_raw = get_object(bucket, key)
        if not email_body_raw:
            delete_object(bucket, key)
    if not email_body_raw:
        client = get_imap_client(IMAP_HOST, user, folder, True)
        message = client.fetch([msg_id],['RFC822'])
        client.logout()
        # A UID FETCH for a UID that is no longer in the mailbox succeeds and
        # returns an empty dict, so the subscript below is not guaranteed.
        if msg_id not in message:
            raise MessageGoneError(folder, msg_id)
        email_body_raw = message[msg_id][b'RFC822']
        if not email_body_raw:
            raise MessageGoneError(folder, msg_id)
        upload_object(bucket, key, "text/plain", email_body_raw)
    message = email.message_from_bytes(email_body_raw, policy=default_policy)
    return message

def upload_object(bucket, key, content_type, obj):
    '''Uploads an object to s3'''
    with io.BytesIO() as f:
        f.write(obj)
        f.seek(0)
        try:
            s3c.upload_fileobj(f, bucket, key, ExtraArgs={'ContentType': content_type})
        except ClientError as e:
            logging.error(e)
            return False
    return True

def get_object(bucket, key):
    '''Returns an object from s3'''
    obj = s3r.Object(bucket, key)
    return obj.get()['Body'].read()

def delete_object(bucket, key):
    '''Deletes an object from s3. Returns True on success, False on error.'''
    try:
        s3r.Object(bucket, key).delete()
    except ClientError as e:
        logging.error(e)
        return False
    return True

def delete_prefix(bucket, prefix):
    '''Deletes every object under a key prefix. Returns True on success,
    False on error. The prefix must be non-empty and end with "/" so a
    folder prefix can never match a sibling folder's keys.'''
    if not prefix or not prefix.endswith('/'):
        raise ValueError(f'invalid delete prefix: {prefix!r}')
    try:
        responses = s3r.Bucket(bucket).objects.filter(Prefix=prefix).delete()
    except ClientError as e:
        logging.error(e)
        return False
    # The batch DeleteObjects API authorizes per key and reports a refused key
    # inside a 200 response instead of raising, so a permissions failure here
    # is silent unless the Errors array is read back.
    responses = responses or []
    errors = [err for response in responses for err in response.get('Errors', [])]
    if errors:
        deleted = sum(len(response.get('Deleted', [])) for response in responses)
        logging.error('delete_prefix %s/%s: %s keys refused (%s deleted), first: %s',
                      bucket, prefix, len(errors), deleted, errors[0])
        return False
    return True

def sign_url(bucket, key, expiration=86400):
    '''Signs a URL for an object hosted in s3'''
    params = {
        'Bucket': bucket,
        'Key': key
    }
    try:
        url = s3c.generate_presigned_url('get_object',
                                        Params=params,
                                        ExpiresIn=expiration)
    except Exception as e:  # pylint: disable=broad-exception-caught
        logging.error(e)
        return "Error"
    return url

def sign_put_url(bucket, key, expiration=600):
    '''Signs a PUT URL for direct browser/native uploads to s3.

    The caller PUTs the file body straight to the returned URL, bypassing
    API Gateway's 10 MB request ceiling. The presigned URL only authorizes
    a single key, so the Lambda that issues it is responsible for scoping
    keys to the authenticated user. Content-Type is intentionally not
    bound here so clients can PUT without negotiating header values; the
    consumer of the uploaded object (currently `/send`) is the source of
    truth for the file's MIME type.
    '''
    params = {
        'Bucket': bucket,
        'Key': key
    }
    try:
        url = s3c.generate_presigned_url('put_object',
                                        Params=params,
                                        ExpiresIn=expiration)
    except Exception as e:  # pylint: disable=broad-exception-caught
        logging.error(e)
        return "Error"
    return url

def key_exists(bucket, key):
    '''checks wither a key exists in a given bucket'''
    try:
        s3r.Object(bucket, key).load()
    except ClientError as e:
        if e.response['Error']['Code'] != "404":
            logging.error(e)
        return False
    return True


# Envelope decoders shared by /list_envelopes and /search_envelopes. Both
# endpoints return the same per-envelope JSON shape; the helpers live here so
# the wire format stays in sync and pylint's duplicate-code check stays quiet.

# References is not part of the RFC 3501 ENVELOPE, so it rides the same
# header fetch as X-PRIORITY, as does Authentication-Results (stamped by
# the smtp-in verification milters — phase 2 of
# docs/0.10.x/inbound-auth-verification-plan.md). imapclient keys the
# response dict by the requested atom, so the constant and the lookup in
# envelope_dict must stay in lockstep — hence the single shared key.
ENVELOPE_HEADER_FIELDS_KEY = \
    'BODY[HEADER.FIELDS (X-PRIORITY REFERENCES AUTHENTICATION-RESULTS)]'

ENVELOPE_FETCH_KEYS = [
    'ENVELOPE', 'FLAGS', 'BODYSTRUCTURE', ENVELOPE_HEADER_FIELDS_KEY
]

# Deep threads grow References without bound and envelopes are fetched ~50 at
# a time, so emit only the newest ids. RFC 5322 itself sanctions trimming old
# ids; reply threading only ever appends one id to what it received.
MAX_REFERENCES_IDS = 20

_MSGID_RE = re.compile(r'<[^<>]+>')

# RFC 8601 method=result at the start of one ;-separated resinfo segment.
# Only the verdict token is surfaced; comments and properties (header.d,
# smtp.mailfrom, ...) stay in the raw header for the view-source modal.
_AUTH_RESULT_RE = re.compile(r'^\s*(spf|dkim|dmarc)\s*=\s*([A-Za-z0-9]+)')


def parse_auth_results(headers):
    '''Extracts SPF/DKIM/DMARC verdicts from Authentication-Results headers.

    Only headers whose authserv-id is exactly the environment's control
    domain are trusted: the smtp-in milters stamp under that identity and
    strip inbound headers claiming it (phase 1 of
    docs/0.10.x/inbound-auth-verification-plan.md), so this check is
    defense in depth against a forged header arriving by any other path.
    The milters emit one header per method, most recent first; the first
    verdict seen for a method wins.

    Returns e.g. {"spf": "pass", "dkim": "pass", "dmarc": "fail"} with a
    key per method found, or None when no trusted header exists
    (pre-feature mail, internally-routed mail that bypassed smtp-in).
    Clients must render None as "not verified", never as pass.
    '''
    if not CONTROL_DOMAIN:
        return None
    results = {}
    for raw in headers.get_all('Authentication-Results') or []:
        authserv, _, resinfo = str(raw).partition(';')
        # authserv-id may carry an RFC 8601 version token ("example.com 1").
        authserv_words = authserv.split()
        if not authserv_words or authserv_words[0].lower() != CONTROL_DOMAIN.lower():
            continue
        for segment in resinfo.split(';'):
            match = _AUTH_RESULT_RE.match(segment)
            if match and match.group(1) not in results:
                results[match.group(1)] = match.group(2).lower()
    return results or None


def parse_message_ids(raw):
    '''Extracts the angle-bracketed message-ids from a header value.

    Accepts bytes or str (IMAP ENVELOPE fields arrive as bytes) and returns a
    list of `<id>` strings — the same wire shape /fetch_message emits — so
    client-side decoders are shared between the two payloads.
    '''
    if raw is None:
        return []
    if isinstance(raw, bytes):
        raw = raw.decode(errors='replace')
    return _MSGID_RE.findall(raw)


def envelope_dict(msgid, data):
    '''Builds the per-envelope JSON payload from one IMAP fetch result entry.

    Callers are expected to have requested ENVELOPE_FETCH_KEYS in their fetch.
    The shape is consumed by the React webmail and the Apple `CabalmailKit`
    decoders, so changes here ripple to both clients.
    '''
    envelope = data[b'ENVELOPE']
    # The header blob now carries two fields with possible RFC 5322 folding,
    # so parse it properly instead of splitting on whitespace.
    headers = HeaderParser().parsestr(
        data.get(ENVELOPE_HEADER_FIELDS_KEY.encode(), b'').decode(errors='replace')
    )
    priority_header = headers.get('X-Priority') or ''
    return {
        "id": msgid,
        "date": str(envelope.date),
        "subject": decode_subject(envelope.subject),
        "from": decode_address(envelope.from_),
        "to": decode_address(envelope.to),
        "cc": decode_address(envelope.cc),
        # Populated only for messages whose stored copy carries a Bcc header -
        # in practice the user's own Sent mail - and empty everywhere else.
        # Reply-from-Sent needs it to reconstruct the original recipient set.
        "bcc": decode_address(envelope.bcc),
        "flags": decode_flags(data[b'FLAGS']),
        "struct": decode_body_structure(data[b'BODYSTRUCTURE']),
        "priority": [f"priority-{s}" for s in priority_header.split() if s.isdigit()],
        "message_id": parse_message_ids(envelope.message_id),
        "in_reply_to": parse_message_ids(envelope.in_reply_to),
        "references": parse_message_ids(headers.get('References'))[-MAX_REFERENCES_IDS:],
        "auth_results": parse_auth_results(headers)
    }


def decode_subject(data):
    '''Converts an email subject into a utf-8 string'''
    if data is None:
        return ''
    try:
        subject_parts = decode_header(data.decode())
    except UnicodeDecodeError:
        return "[[¿?]]"
    subject_strings = []
    for part in subject_parts:
        try:
            if isinstance(part[0], bytes):
                subject_strings.append(str(part[0], part[1] or 'utf-8'))
            if isinstance(part[0], str):
                subject_strings.append(part[0])
        except UnicodeDecodeError:
            subject_strings.append("[¿?]")
    return ''.join(subject_strings)


def decode_name(raw):
    '''Decodes an RFC 2047 encoded display name to a utf-8 string'''
    if raw is None:
        return ''
    try:
        if isinstance(raw, bytes):
            raw = raw.decode()
    except UnicodeDecodeError:
        return ''
    try:
        parts = decode_header(raw)
    except (UnicodeDecodeError, ValueError):
        return raw
    pieces = []
    for value, charset in parts:
        if isinstance(value, bytes):
            try:
                pieces.append(value.decode(charset or 'utf-8', errors='replace'))
            except (LookupError, UnicodeDecodeError):
                pieces.append(value.decode('utf-8', errors='replace'))
        else:
            pieces.append(value)
    return ''.join(pieces).strip()


def format_mailbox(name, addr):
    '''Renders an RFC 5322 mailbox string, quoting the display name when one is set'''
    if name:
        # Quote and escape the display name for safe RFC 5322 rendering. Existing
        # clients parse `"Name" <addr@host>` via a `<...>` regex.
        escaped = name.replace('\\', '\\\\').replace('"', '\\"')
        return f'"{escaped}" <{addr}>'
    return addr


def format_address(fragment):
    '''Renders one ENVELOPE address in RFC 5322 mailbox form, including display name when set'''
    mailbox = fragment.mailbox.decode()
    host = fragment.host.decode()
    name = decode_name(fragment.name)
    return format_mailbox(name, f"{mailbox}@{host}")


def decode_address(data):
    '''Converts a tuple of Address objects to a list of RFC 5322 mailbox strings'''
    return_value = []
    if isinstance(data, type(None)):
        return return_value
    for fragment in data:
        try:
            return_value.append(format_address(fragment))
        except: # pylint: disable=bare-except
            return_value.append("undisclosed-recipients")
    return return_value


def decode_flags(data):
    '''Converts array of bytes to array of strings'''
    return_value = []
    for flag in data:
        return_value.append(flag.decode())
    return return_value


def decode_body_structure(data):
    '''Converts bytes to strings in body structure'''
    return_value = []
    for obj in data:
        if isinstance(obj, list):
            return_value.append(decode_body_structure(obj))
        elif isinstance(obj, tuple):
            return_value.append(decode_body_structure(obj))
        elif isinstance(obj, bytes):
            return_value.append(decode_struct_bytes(obj))
        else:
            return_value.append(obj)
    return return_value


def decode_struct_bytes(raw):
    '''Decodes one BODYSTRUCTURE byte string, tolerating non-UTF-8 bytes.

    BODYSTRUCTURE strings are ASCII per RFC 3501, but real-world messages
    leak raw 8-bit bytes into MIME parameter values (unencoded Latin-1
    filenames and the like). A strict decode here fails the whole envelope
    page over one such message, so fall back to Latin-1, which maps every
    byte and keeps the common single-byte-charset case readable.
    '''
    try:
        return raw.decode()
    except UnicodeDecodeError:
        return raw.decode('latin-1')
