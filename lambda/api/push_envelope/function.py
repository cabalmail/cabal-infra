'''Returns the minimal envelope (sender/subject/snippet) for one message.

Called by the Apple clients' Notification Service Extension to enrich a
content-free APNs wake signal on-device, so Apple's push infrastructure never
sees message content (docs/0.11.x/push-notifications.md). The NSE runs against
a hard OS deadline and treats any failure as "show the generic alert", so this
endpoint favors fast, definite answers over completeness.

The wake signal carries the Message-ID and a best-effort UID hint (procmail
enqueues before Dovecot assigns the UID). When msg_id is present it is
authoritative: the folder is searched for it and the resolved UID is returned
so the client can route "Open" to the right message.
'''
import email
import json
from email.policy import default
from html.parser import HTMLParser

from helper import CACHE_BUCKET  # pylint: disable=import-error
from helper import delete_object  # pylint: disable=import-error
from helper import get_imap_client  # pylint: disable=import-error
from helper import get_message  # pylint: disable=import-error
from helper import get_object  # pylint: disable=import-error
from helper import key_exists  # pylint: disable=import-error
from helper import maintenance_guard  # pylint: disable=import-error
from helper import MessageGoneError  # pylint: disable=import-error
from helper import parse_json_body  # pylint: disable=import-error
from helper import upload_object  # pylint: disable=import-error
from helper import validate_folder_name  # pylint: disable=import-error
from helper import validate_message_id  # pylint: disable=import-error
from helper import validate_uid  # pylint: disable=import-error

# The notification preview area is small and iOS truncates aggressively; these
# just bound the response body, they are not display decisions.
MAX_FIELD_LENGTH = 256
MAX_SNIPPET_LENGTH = 240


# pylint: disable-next=abstract-method  # ParserBase.error is gone in py3.10+
class _TextExtractor(HTMLParser):
    '''Collects the text content of an HTML body, skipping script/style.'''

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.chunks = []
        self._suppressed = 0

    def handle_starttag(self, tag, attrs):
        if tag in ('script', 'style'):
            self._suppressed += 1

    def handle_endtag(self, tag):
        if tag in ('script', 'style') and self._suppressed:
            self._suppressed -= 1

    def handle_data(self, data):
        if not self._suppressed:
            self.chunks.append(data)


def _strip_html(markup):
    '''Returns the visible text of an HTML fragment, whitespace-normalized.'''
    extractor = _TextExtractor()
    try:
        extractor.feed(markup)
    except Exception:  # pylint: disable=broad-exception-caught
        return ''
    return ' '.join(''.join(extractor.chunks).split())


def _decoded_text(part):
    '''Returns a MIME part's payload as text, or empty string on any failure.'''
    payload = part.get_payload(decode=True)
    if payload is None:
        return ''
    try:
        return payload.decode(part.get_content_charset() or 'utf-8', errors='replace')
    except LookupError:
        return payload.decode('utf-8', errors='replace')


def _snippet(message):
    '''Extracts a short plain-text preview: first text/plain part, else the
    tag-stripped first text/html part, else empty (never an error).'''
    plain, markup = '', ''
    parts = message.walk() if message.is_multipart() else [message]
    for part in parts:
        if 'attachment' in str(part.get('Content-Disposition')):
            continue
        content_type = part.get_content_type()
        if content_type == 'text/plain' and not plain:
            plain = _decoded_text(part)
        elif content_type == 'text/html' and not markup:
            markup = _decoded_text(part)
        if plain:
            break
    text = ' '.join(plain.split()) if plain else _strip_html(markup)
    return text[:MAX_SNIPPET_LENGTH]


def _load_by_message_id(user, folder, uid_hint, msg_id):
    '''Resolves the real UID by Message-ID search and loads the message on
    the SAME connection (the NSE runs against a hard deadline; a second TLS +
    LOGIN + SELECT handshake is the biggest avoidable cost here), honoring
    and warming the S3 cache like get_message. Returns (uid, message-or-None).
    '''
    client = get_imap_client(None, user, folder, read_only=True)
    try:
        matches = client.search(['HEADER', 'Message-ID', msg_id])
        uid = max(matches) if matches else uid_hint
        if uid is None:
            return None, None
        key = f'{user}/{folder}/{uid}/raw'
        raw = b''
        if key_exists(CACHE_BUCKET, key):
            raw = get_object(CACHE_BUCKET, key)
            if not raw:
                # A zero-byte entry is cache poison, not content (see
                # get_message's docstring); delete it and refetch.
                delete_object(CACHE_BUCKET, key)
        if not raw:
            fetched = client.fetch([uid], ['RFC822'])
            if uid not in fetched:
                # Expunged, or a stale hint with no Message-ID match.
                return uid, None
            raw = fetched[uid][b'RFC822']
            if not raw:
                # A truncated delivery's empty message file: enriching it
                # would blank the alert (empty From/Subject/snippet beat the
                # client's "New mail" fallback) and caching it would poison
                # every later read. Treat it as gone.
                return uid, None
            upload_object(CACHE_BUCKET, key, 'text/plain', raw)
    finally:
        client.logout()
    return uid, email.message_from_bytes(raw, policy=default)


@maintenance_guard
def handler(event, _context):
    '''Returns {from, subject, snippet, uid} for the referenced message.'''
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    body, error = parse_json_body(event)
    if error:
        return error
    try:
        folder = validate_folder_name(str(body.get('folder', ''))).replace('/', '.')
        uid = validate_uid(body.get('uid')) if body.get('uid') else None
    except ValueError as err:
        return {'statusCode': 400, 'body': json.dumps({'Error': str(err)})}
    # msg_id is advisory identity, not a gate: a rejected msg_id must degrade
    # to the uid hint, not 400 the enrichment.
    try:
        msg_id = validate_message_id(body['msg_id']) if body.get('msg_id') else None
    except ValueError:
        msg_id = None
    if uid is None and msg_id is None:
        return {'statusCode': 400, 'body': json.dumps({'Error': 'uid or msg_id is required'})}

    if msg_id:
        uid, message = _load_by_message_id(user, folder, uid, msg_id)
    else:
        try:
            message = get_message(None, user, folder, uid)
        except MessageGoneError:
            message = None
    if uid is None or message is None:
        # No UID resolvable, expunged, or a stale hint.
        return {'statusCode': 404, 'body': json.dumps({'Error': 'message not found'})}

    return {
        'statusCode': 200,
        'body': json.dumps({
            'from': str(message.get('From', ''))[:MAX_FIELD_LENGTH],
            'subject': str(message.get('Subject', ''))[:MAX_FIELD_LENGTH],
            'snippet': _snippet(message),
            'uid': uid,
        })
    }
