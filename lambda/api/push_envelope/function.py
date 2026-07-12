'''Returns the minimal envelope (sender/subject/snippet) for one message.

Called by the Apple clients' Notification Service Extension to enrich a
content-free APNs wake signal on-device, so Apple's push infrastructure never
sees message content (docs/0.11.0/push-notifications.md). The NSE runs against
a hard OS deadline and treats any failure as "show the generic alert", so this
endpoint favors fast, definite answers over completeness.

The wake signal carries the Message-ID and a best-effort UID hint (procmail
enqueues before Dovecot assigns the UID). When msg_id is present it is
authoritative: the folder is searched for it and the resolved UID is returned
so the client can route "Open" to the right message.
'''
import json
from html.parser import HTMLParser

from helper import get_imap_client  # pylint: disable=import-error
from helper import get_message  # pylint: disable=import-error
from helper import maintenance_guard  # pylint: disable=import-error
from helper import parse_json_body  # pylint: disable=import-error
from helper import validate_content_id  # pylint: disable=import-error
from helper import validate_folder_name  # pylint: disable=import-error
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


def _resolve_uid(user, folder, uid, msg_id):
    '''Returns the UID to fetch: the Message-ID search result when available
    (the enqueue-side UID is only a hint), else the caller's hint.'''
    if not msg_id:
        return uid
    client = get_imap_client(None, user, folder, read_only=True)
    try:
        matches = client.search(['HEADER', 'Message-ID', msg_id])
    finally:
        client.logout()
    if matches:
        return max(matches)
    return uid


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
        msg_id = validate_content_id(body['msg_id']) if body.get('msg_id') else None
    except ValueError as err:
        return {'statusCode': 400, 'body': json.dumps({'Error': str(err)})}
    if uid is None and msg_id is None:
        return {'statusCode': 400, 'body': json.dumps({'Error': 'uid or msg_id is required'})}

    uid = _resolve_uid(user, folder, uid, msg_id)
    if uid is None:
        return {'statusCode': 404, 'body': json.dumps({'Error': 'message not found'})}
    try:
        message = get_message(None, user, folder, uid)
    except KeyError:
        # client.fetch returned no entry for the UID: expunged or a stale hint.
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
