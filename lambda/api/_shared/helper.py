'''Shared helpers for the Cabalmail Lambda API: IMAP client/auth, DynamoDB
address lookups, S3 message caching and presigned URLs, envelope decoding, and
the request-input validators used across the handlers.'''
import email
import functools
import io
import json
import logging
import os
import re
import time
from email.header import decode_header
from email.policy import default as default_policy
import boto3  # pylint: disable=import-error
from botocore.exceptions import ClientError  # pylint: disable=import-error
from imapclient import IMAPClient  # pylint: disable=import-error

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


def admin_response_or_none(event):
    """Returns a 403 response when the caller lacks the admin group, else None"""
    groups = event['requestContext']['authorizer']['claims'].get('cognito:groups', '')
    if 'admin' not in groups:
        return {
            'statusCode': 403,
            'body': json.dumps({'Error': 'Admin access required'})
        }
    return None

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

def get_imap_client(host, user, folder, read_only=False):
    '''Returns an IMAP client for host/user with folder selected.

    Raises MaintenanceError when a planned IMAP roll is in progress, so callers
    short-circuit to a friendly 503 (via maintenance_guard) instead of dialing a
    server that is mid-restart. Every IMAP-touching path flows through here, so
    this one check covers reads, folder ops, flags, moves, and cache-miss
    fetches; cache hits never reach this function and keep working.'''
    _raise_if_maintenance()
    client = IMAPClient(host=host, use_uid=True, ssl=True)
    client.login(f"{user}*admin", mpw)
    client.select_folder(folder, read_only)
    return client

def user_authorized_for_sender(user, sender):
    """Checks whether the user is allowed to send from the specifed sender address"""
    try:
        response = ddb_table.get_item(Key={'address': sender})
    except ClientError as err:
        print(err.response['Error']['Message'])
        return False
    try:
        return response['Item']['user'] == user
    except KeyError:
        return False

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


# ---------------------------------------------------------------------------
# Input validators (Phase 3 of docs/0.10.x/application-surface-hardening-plan).
#
# The IMAP-shaped handlers take folder names, UID lists, flags, sort keys, and
# S3-key fragments from query strings and JSON bodies. The master-user model
# already scopes every operation to the caller's own mailbox, so these are
# defence-in-depth against a future shape change rather than live exploits --
# but rejecting malformed input at the boundary (ValueError -> 400) beats
# relaying it into Dovecot and surfacing a 500 traceback or an opaque IMAP
# protocol error. Each validator raises ValueError with a sanitized message;
# handlers translate that into a 400.
# ---------------------------------------------------------------------------

# Shared with the large-mailbox chunking work; one ceiling for both surfaces.
MAX_IDS_PER_REQUEST = 5000
MAX_FOLDER_NAME_BYTES = 255
MAX_KEYWORD_LEN = 64
MAX_CONTENT_ID_LEN = 128
MAX_SEARCH_TEXT_LEN = 1024
MAX_UID = 0xFFFFFFFF

_FOLDER_NAME_RE = re.compile(r'^[A-Za-z0-9 _\-./]+$')
_KEYWORD_RE = re.compile(r'^[A-Za-z0-9_\-]+$')
_CONTROL_CHARS_RE = re.compile(r'[\x00-\x1f\x7f]')
_CONTENT_ID_FORBIDDEN_RE = re.compile(r'[\x00-\x1f\x7f\s/\\]')

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

# The two trash folder names in active use: Dovecot's special-use \Trash
# mailbox ("Trash", used by the Apple clients) and the React client's
# auto-created "Deleted Messages". Destructive endpoints (purge_messages,
# empty_trash) only operate on these so a client bug can never expunge a
# non-trash folder.
TRASH_FOLDERS = ('Trash', 'Deleted Messages')


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


class ZoneMismatchError(Exception):
    '''Raised when a hosted-zone id does not actually own the apex the DOMAINS
    env var maps it to. Signals operator/Terraform drift, not user error.'''


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
    '''Unsubscribes the user from an IMAP folder.'''
    client = get_imap_client(host, user, folder)
    return_value = client.unsubscribe_folder(folder)
    client.logout()
    return return_value

def get_message(host, user, folder, msg_id):
    '''Gets a message from cache on s3 or from imap server'''
    bucket = host.replace("imap", "cache")
    email_body_raw = b''
    key = f"{user}/{folder}/{msg_id}/raw"
    if key_exists(bucket, key):
        email_body_raw = get_object(bucket, key)
    else:
        client = get_imap_client(host, user, folder, True)
        message = client.fetch([msg_id],['RFC822'])
        email_body_raw = message[msg_id][b'RFC822']
        client.logout()
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
        s3r.Bucket(bucket).objects.filter(Prefix=prefix).delete()
    except ClientError as e:
        logging.error(e)
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

ENVELOPE_FETCH_KEYS = [
    'ENVELOPE', 'FLAGS', 'BODYSTRUCTURE', 'BODY[HEADER.FIELDS (X-PRIORITY)]'
]


def envelope_dict(msgid, data):
    '''Builds the per-envelope JSON payload from one IMAP fetch result entry.

    Callers are expected to have requested ENVELOPE_FETCH_KEYS in their fetch.
    The shape is consumed by the React webmail and the Apple `CabalmailKit`
    decoders, so changes here ripple to both clients.
    '''
    envelope = data[b'ENVELOPE']
    priority_header = data[b'BODY[HEADER.FIELDS (X-PRIORITY)]'].decode()
    return {
        "id": msgid,
        "date": str(envelope.date),
        "subject": decode_subject(envelope.subject),
        "from": decode_address(envelope.from_),
        "to": decode_address(envelope.to),
        "cc": decode_address(envelope.cc),
        "flags": decode_flags(data[b'FLAGS']),
        "struct": decode_body_structure(data[b'BODYSTRUCTURE']),
        "priority": [f"priority-{s}" for s in priority_header.split() if s.isdigit()]
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


def format_address(fragment):
    '''Renders one ENVELOPE address in RFC 5322 mailbox form, including display name when set'''
    mailbox = fragment.mailbox.decode()
    host = fragment.host.decode()
    addr = f"{mailbox}@{host}"
    name = decode_name(fragment.name)
    if name:
        # Quote and escape the display name for safe RFC 5322 rendering. Existing
        # clients parse `"Name" <addr@host>` via a `<...>` regex.
        escaped = name.replace('\\', '\\\\').replace('"', '\\"')
        return f'"{escaped}" <{addr}>'
    return addr


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
            return_value.append(obj.decode())
        else:
            return_value.append(obj)
    return return_value
