'''Structured single-folder search returning envelopes plus a pagination cursor.

Phase 1 of `docs/0.9.x/imap-search-plan.md`. The endpoint accepts a structured
query (no raw IMAP-SEARCH syntax leaks across the wire), translates it to an
IMAP SEARCH criteria list server-side, sorts matches newest-first, and returns
the same per-envelope shape as `/list_envelopes` together with an opaque
cursor for the next page. Single-folder only - cross-folder is Phase 3. No FTS
yet (Phase 4), so body search is whatever Dovecot's sequential scan gives us.

The old raw-syntax `/search` endpoint stays in place during the migration
window so the Apple client keeps working until Phase 5 cuts it over.
'''
import base64
import datetime
import json
from helper import ( # pylint: disable=import-error
    ENVELOPE_FETCH_KEYS,
    envelope_dict,
    get_imap_client,
)

MAX_RESULTS = 5000
DEFAULT_LIMIT = 50
MAX_LIMIT = 200
TRUTHY = {'1', 'true', 'True', 'yes', 'YES'}


def handler(event, _context):
    '''Searches one folder using structured query params and returns envelopes.

    Required query params: `host`, `folder`. Optional: `text`, `from`, `to`,
    `subject`, `since` (YYYY-MM-DD), `before` (YYYY-MM-DD), `unread`,
    `flagged`, `has_attachment`, `limit` (default 50, max 200), `cursor`.

    Response shape:

        {
          "envelopes": [...],            // newest-first; per-envelope shape
                                         // matches /list_envelopes
          "total_estimate": 137,         // exact unless truncated == true
          "next_cursor": "...",          // null on the last page
          "folders_searched": ["INBOX"],
          "truncated": false             // true when the match set hit
                                         // MAX_RESULTS before pagination
        }

    The cursor is opaque to clients. It encodes (last_internal_date, last_uid)
    of the previous page tail so successive pages survive modest mailbox churn
    without holding server-side state. UTF-8 is the only accepted charset; the
    Lambda sets `CHARSET UTF-8` on every SEARCH so non-ASCII literals are
    interpreted consistently.
    '''
    qs = event.get('queryStringParameters') or {}
    user = event['requestContext']['authorizer']['claims']['cognito:username']

    try:
        req = parse_request(qs)
    except ValueError as exc:
        return _error(400, str(exc))

    client = get_imap_client(req['host'], user, req['folder'].replace('/', '.'), True)
    try:
        pairs, truncated = search_and_sort(client, req['criteria'], req['want_attachment'])
        remaining = apply_cursor(pairs, req['cursor'])
        page = remaining[:req['limit']]
        envelopes = fetch_envelopes(client, [u for _, u in page])
        next_cursor = build_next_cursor(remaining, page)
    finally:
        client.logout()

    return {
        "statusCode": 200,
        "body": json.dumps({
            "envelopes": envelopes,
            "total_estimate": len(pairs),
            "next_cursor": next_cursor,
            "folders_searched": [req['folder']],
            "truncated": truncated,
        })
    }


def parse_request(qs):
    '''Extracts and validates request parameters. Raises ValueError on bad input.'''
    folder = qs.get('folder')
    host = qs.get('host')
    if not folder or not host:
        raise ValueError('host and folder are required')
    cursor = decode_cursor(qs.get('cursor'))
    return {
        'host': host,
        'folder': folder,
        'cursor': cursor,
        'criteria': build_criteria(qs, cursor),
        'limit': clamp_limit(qs.get('limit')),
        'want_attachment': qs.get('has_attachment') in TRUTHY,
    }


def build_criteria(qs, cursor):
    '''Translates structured query params into an IMAP SEARCH criteria list.'''
    criteria = []

    text = (qs.get('text') or '').strip()
    if text:
        # Tokenize on whitespace; AND-of-terms via repeated TEXT keys. TEXT
        # matches both headers and body. Phrase quoting and boolean operators
        # are deliberately out of scope for the Phase 1 contract.
        for token in text.split():
            criteria.extend(['TEXT', token])

    for field, key in (('from', 'FROM'), ('to', 'TO'), ('subject', 'SUBJECT')):
        value = (qs.get(field) or '').strip()
        if value:
            criteria.extend([key, value])

    for field, key in (('since', 'SINCE'), ('before', 'BEFORE')):
        value = (qs.get(field) or '').strip()
        if value:
            criteria.extend([key, _parse_iso_date(value, field)])

    if qs.get('unread') in TRUTHY:
        criteria.append('UNSEEN')
    if qs.get('flagged') in TRUTHY:
        criteria.append('FLAGGED')

    # IMAP BEFORE is day-granular, so cursor pruning adds
    # `BEFORE (cursor_date + 1)` to constrain to same-day-or-older messages.
    # The same-day boundary (already-seen UIDs from the previous page) is
    # filtered precisely in Python once INTERNALDATE is fetched.
    if cursor is not None:
        cur_d = datetime.date.fromisoformat(cursor['last_date'])
        criteria.extend(['BEFORE', cur_d + datetime.timedelta(days=1)])

    return criteria or ['ALL']


def search_and_sort(client, criteria, want_attachment):
    '''Runs SEARCH, applies the MAX_RESULTS cap, fetches metadata, and sorts
    newest-first. Returns (sorted_pairs, truncated_flag).'''
    uids = list(client.search(criteria, charset='UTF-8'))
    truncated = len(uids) > MAX_RESULTS
    if truncated:
        uids = uids[:MAX_RESULTS]
    return _sort_pairs(client, uids, want_attachment), truncated


def _sort_pairs(client, uids, want_attachment):
    '''Fetches INTERNALDATE (and BODYSTRUCTURE when filtering attachments) for
    `uids` and returns a (date, uid) list sorted newest-first.'''
    if not uids:
        return []
    fetch_keys = ['INTERNALDATE']
    if want_attachment:
        fetch_keys.append('BODYSTRUCTURE')
    meta = client.fetch(uids, fetch_keys)

    if want_attachment:
        uids = [
            u for u in uids
            if u in meta and bodystructure_has_attachment(meta[u].get(b'BODYSTRUCTURE'))
        ]

    pairs = []
    for u in uids:
        data = meta.get(u)
        if not data:
            continue
        idate = data.get(b'INTERNALDATE')
        if idate is None:
            continue
        pairs.append((idate.date(), u))
    pairs.sort(key=lambda p: (p[0], p[1]), reverse=True)
    return pairs


def apply_cursor(pairs, cursor):
    '''Drops everything in `pairs` that the previous page already returned.'''
    if cursor is None:
        return pairs
    cur_d = datetime.date.fromisoformat(cursor['last_date'])
    cur_u = int(cursor['last_uid'])
    return [p for p in pairs if (p[0], p[1]) < (cur_d, cur_u)]


def build_next_cursor(remaining, page):
    '''Encodes the next-page cursor from the tail of `page`, or returns None
    when `page` already exhausts `remaining`.'''
    if not page or len(remaining) <= len(page):
        return None
    last_d, last_u = page[-1]
    return encode_cursor({
        'last_date': last_d.isoformat(),
        'last_uid': int(last_u),
    })


def clamp_limit(raw):
    '''Clamps `limit` to [1, MAX_LIMIT]; falls back to DEFAULT_LIMIT on garbage.'''
    try:
        n = int(raw) if raw not in (None, '') else DEFAULT_LIMIT
    except (TypeError, ValueError):
        n = DEFAULT_LIMIT
    return max(1, min(n, MAX_LIMIT))


def encode_cursor(payload):
    '''Encodes a pagination cursor as URL-safe base64 of a compact JSON object.'''
    raw = json.dumps(payload, sort_keys=True, separators=(',', ':')).encode('utf-8')
    return base64.urlsafe_b64encode(raw).decode('ascii').rstrip('=')


def decode_cursor(token):
    '''Decodes a pagination cursor; returns None when absent. Raises ValueError
    when the cursor is malformed or missing required fields.'''
    if not token:
        return None
    padded = token + '=' * (-len(token) % 4)
    try:
        raw = base64.urlsafe_b64decode(padded.encode('ascii'))
        payload = json.loads(raw.decode('utf-8'))
    except (ValueError, UnicodeDecodeError) as exc:
        raise ValueError('invalid cursor') from exc
    if not isinstance(payload, dict) or 'last_date' not in payload or 'last_uid' not in payload:
        raise ValueError('invalid cursor')
    try:
        datetime.date.fromisoformat(payload['last_date'])
        int(payload['last_uid'])
    except (TypeError, ValueError) as exc:
        raise ValueError('invalid cursor') from exc
    return payload


def bodystructure_has_attachment(bs):
    '''Heuristic: any multipart/mixed subtree implies a user-visible attachment.

    multipart/mixed is the conventional container for messages with attached
    files; multipart/alternative and multipart/related are inline body parts.
    Inline images, calendar invites, and a handful of other shapes may be
    miscategorised in either direction; the heuristic tightens in Phase 4
    once FTS lands and a dedicated header/index predicate replaces it.
    '''
    if not isinstance(bs, (tuple, list)) or len(bs) < 2:
        return False
    first = bs[0]
    if not isinstance(first, (list, tuple)):
        return False  # single-part body
    subtype = _bytes_to_str(bs[1]).lower()
    if subtype == 'mixed':
        return True
    for child in first:
        if bodystructure_has_attachment(child):
            return True
    return False


def fetch_envelopes(client, ids):
    '''Hydrates `ids` into the envelope shape used by /list_envelopes.

    Returns a list whose order matches `ids` so the caller's newest-first
    sort survives the IMAP fetch round-trip (the server is free to return
    fetched items in any order).
    '''
    if not ids:
        return []
    fetched = client.fetch(ids, ENVELOPE_FETCH_KEYS)
    envelopes = []
    for msgid in ids:
        data = fetched.get(msgid)
        if data is None:
            continue
        envelopes.append(envelope_dict(msgid, data))
    return envelopes


def _parse_iso_date(value, field):
    try:
        return datetime.date.fromisoformat(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f'invalid {field}: {value!r} (expected YYYY-MM-DD)') from exc


def _bytes_to_str(value):
    if isinstance(value, bytes):
        try:
            return value.decode('ascii')
        except UnicodeDecodeError:
            return ''
    if isinstance(value, str):
        return value
    return ''


def _error(status, message):
    return {
        "statusCode": status,
        "body": json.dumps({"Error": message})
    }
