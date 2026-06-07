'''Structured search returning envelopes plus a pagination cursor.

Phases 1 + 3 of `docs/0.9.x/imap-search-plan.md`. The endpoint accepts a
structured query (no raw IMAP-SEARCH syntax leaks across the wire), translates
it to an IMAP SEARCH criteria list server-side, sorts matches newest-first,
and returns the same per-envelope shape as `/list_envelopes` together with an
opaque cursor for the next page.

When `folder` is supplied the search is single-folder. When `folder` is
omitted (or empty) the Lambda enumerates the user's subscribed folders,
excludes Trash, runs SEARCH against each in turn, merges the matches
newest-first, and stamps each result envelope with its source folder. The
5,000-result cap applies to the merged match set. No FTS yet (Phase 4),
so body search is whatever Dovecot's sequential scan gives us.

The old raw-syntax `/search` endpoint stays in place during the migration
window so the Apple client keeps working until Phase 5 cuts it over.
'''
import base64
import datetime
import json
from imapclient.exceptions import IMAPClientError # pylint: disable=import-error
from helper import ( # pylint: disable=import-error
    ENVELOPE_FETCH_KEYS,
    envelope_dict,
    get_imap_client,
    maintenance_guard,
    validate_folder_name,
    validate_search_text,
)

MAX_RESULTS = 5000
DEFAULT_LIMIT = 50
MAX_LIMIT = 200
TRUTHY = {'1', 'true', 'True', 'yes', 'YES'}

# Path segments excluded from cross-folder ("all folders") search by default.
# Matched case-insensitively against each `/`-separated segment, so a nested
# `Archive/Trash` is also excluded. Trash is the only excluded folder —
# Spam / Junk / Deleted Messages are searchable because users do legitimately
# need to find misclassified mail in them. The list is intended to line up
# with the FTS-autoindex exclude list that Phase 4 ships.
CROSS_FOLDER_EXCLUDES = {'trash'}


@maintenance_guard
def handler(event, _context):
    '''Searches one folder (or every subscribed folder) and returns envelopes.

    Required query params: `host`. Optional: `folder` (omit for cross-folder
    search), `text`, `from`, `to`, `subject`, `since` (YYYY-MM-DD), `before`
    (YYYY-MM-DD), `unread`, `flagged`, `has_attachment`, `limit` (default 50,
    max 200), `cursor`.

    Response shape:

        {
          "envelopes": [...],            // newest-first; per-envelope shape
                                         // matches /list_envelopes plus a
                                         // `folder` field naming the source
                                         // folder (always set, even in
                                         // single-folder mode)
          "total_estimate": 137,         // exact unless truncated == true
          "next_cursor": "...",          // null on the last page
          "folders_searched": ["INBOX", "Archive", ...],
          "truncated": false             // true when the match set hit
                                         // MAX_RESULTS before pagination
        }

    The cursor is opaque to clients. It encodes (last_internal_date,
    last_folder, last_uid) of the previous page tail so successive pages
    survive modest mailbox churn without holding server-side state. UTF-8
    is the only accepted charset; the Lambda sets `CHARSET UTF-8` on every
    SEARCH so non-ASCII literals are interpreted consistently.
    '''
    qs = event.get('queryStringParameters') or {}
    user = event['requestContext']['authorizer']['claims']['cognito:username']

    try:
        req = parse_request(qs)
    except ValueError as exc:
        return _error(400, str(exc))

    # Cross-folder mode discovers folders via LIST on a logged-in session,
    # so we have to be logged in before we know the folder set. INBOX is the
    # safe initial selection; the per-folder loop re-selects as needed.
    initial = req['folder'] or 'INBOX'
    client = get_imap_client(req['host'], user, initial.replace('/', '.'), True)
    try:
        if req['folder'] is not None:
            folders_searched = [req['folder']]
        else:
            folders_searched = enumerate_cross_folder(client)
        triples, truncated = search_folders(
            client, folders_searched, req['criteria'], req['want_attachment'],
        )
        remaining = apply_cursor(triples, req['cursor'])
        page = remaining[:req['limit']]
        envelopes = fetch_envelopes_grouped(client, page)
        next_cursor = build_next_cursor(remaining, page)
    finally:
        _safe_logout(client)

    return {
        "statusCode": 200,
        "body": json.dumps({
            "envelopes": envelopes,
            "total_estimate": len(triples),
            "next_cursor": next_cursor,
            "folders_searched": folders_searched,
            "truncated": truncated,
        })
    }


def parse_request(qs):
    '''Extracts and validates request parameters. Raises ValueError on bad input.

    `folder` is optional; omitting it (or passing an empty string) triggers
    cross-folder mode. `host` remains required.
    '''
    host = qs.get('host')
    if not host:
        raise ValueError('host is required')
    folder = qs.get('folder')
    if folder == '':
        folder = None
    if folder is not None:
        validate_folder_name(folder)
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

    text = (validate_search_text(qs.get('text')) or '').strip()
    if text:
        # Tokenize on whitespace; AND-of-terms via repeated TEXT keys. TEXT
        # matches both headers and body. Phrase quoting and boolean operators
        # are deliberately out of scope for the structured contract.
        for token in text.split():
            criteria.extend(['TEXT', token])

    for field, key in (('from', 'FROM'), ('to', 'TO'), ('subject', 'SUBJECT')):
        value = (validate_search_text(qs.get(field)) or '').strip()
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
    # The same-day boundary (already-seen UIDs / earlier-sort folders from
    # the previous page) is filtered precisely in Python once INTERNALDATE
    # is fetched. Folder-agnostic - the same date prune applies to every
    # folder we walk in cross-folder mode.
    if cursor is not None:
        cur_d = datetime.date.fromisoformat(cursor['last_date'])
        criteria.extend(['BEFORE', cur_d + datetime.timedelta(days=1)])

    return criteria or ['ALL']


def enumerate_cross_folder(client):
    '''Subscribed folders in `/`-separated display form, minus the cross-folder
    noise list and `\\Noselect` containers. INBOX is hoisted to the top so the
    walk order is deterministic and matches the helper's folder sort.'''
    raw = client.list_sub_folders()
    folders = []
    for entry in raw:
        flags = entry[0] or ()
        name = entry[2]
        if any(_flag_str(f).lower() == '\\noselect' for f in flags):
            continue
        display = name.replace('.', '/')
        segments = [s.lower() for s in display.split('/')]
        if any(s in CROSS_FOLDER_EXCLUDES for s in segments):
            continue
        folders.append(display)
    folders.sort(key=lambda k: k if k == 'INBOX' else k.lower())
    return folders


def _flag_str(value):
    if isinstance(value, bytes):
        return value.decode('ascii', errors='replace')
    if isinstance(value, str):
        return value
    return ''


def search_folders(client, folders, criteria, want_attachment):
    '''Runs SEARCH against each folder in turn, accumulates the matches with
    their per-folder metadata, and returns the merged list sorted newest-first
    plus a truncation flag.

    Per-folder cap and merged cap both observe MAX_RESULTS. A single overflowing
    folder marks the query truncated and consumes the remaining budget; the
    walk stops once the budget is exhausted.

    Per-folder SELECT and SEARCH failures are caught and the folder is skipped:
    a stale LSUB entry (subscription that points at a deleted or renamed folder)
    or an FTS-enforced SEARCH failure on a single folder should not blow up the
    whole cross-folder query. The failure is logged so the operator can see
    which folder fell out and clean up if needed.

    When the failure is specifically "the mailbox doesn't exist" -- detected
    via either the RFC 3501 `TRYCREATE` response code or Dovecot's prose; see
    `_is_missing_mailbox` -- the dangling LSUB entry is unsubscribed in-line
    so the same orphan does not keep producing log noise on every future
    cross-folder query. Other `IMAPClientError`s are left as a skip-only:
    a transient EFS hiccup, a lock conflict, or any other non-"doesn't exist"
    SELECT failure must not silently destroy a legitimate subscription.
    '''
    all_triples = []
    truncated = False
    for folder in folders:
        remaining_cap = MAX_RESULTS - len(all_triples)
        if remaining_cap <= 0:
            truncated = True
            break
        try:
            client.select_folder(folder.replace('/', '.'), readonly=True)
            uids = list(client.search(criteria, charset='UTF-8'))
        except IMAPClientError as exc:
            print(f"[search_envelopes] skipping folder {folder!r}: {exc}")
            if _is_missing_mailbox(exc):
                _unsubscribe_stale(client, folder)
            continue
        if len(uids) > remaining_cap:
            uids = uids[:remaining_cap]
            truncated = True
        all_triples.extend(_triples_for(client, folder, uids, want_attachment))
    all_triples.sort(key=lambda t: (t[0], t[1], t[2]), reverse=True)
    return all_triples, truncated


def _is_missing_mailbox(exc):
    '''Returns True when the exception clearly indicates the mailbox does not
    exist, as opposed to a transient or unrelated SELECT failure.

    Two signals, either one sufficient:
      * `TRYCREATE` -- the RFC 3501 7.1 response code that an IMAP server sends
        to mean "this mailbox doesn't exist." The most reliable marker when the
        response code survives imapclient's wrapping.
      * Dovecot's prose ("Mailbox doesn't exist" / "does not exist") -- catches
        the case where imaplib drops the bracketed response code and we are
        left with just the human-readable reason. Stable across the Dovecot
        versions we run; the only thing that would invalidate it is upstream
        rephrasing the error, which would show up as an immediate regression
        in CloudWatch and is easy to update if it ever happens.

    Both are matched case-insensitively. Other `IMAPClientError`s -- transient
    EFS issues, lock contention, auth failures -- fall through and the folder
    is only skipped, never unsubscribed.
    '''
    text = str(exc).lower()
    return (
        'trycreate' in text
        or "doesn't exist" in text
        or 'does not exist' in text
    )


def _unsubscribe_stale(client, folder):
    '''Removes the dangling LSUB entry for a folder that no longer exists.

    Failures from the UNSUBSCRIBE itself are swallowed and logged so the
    self-heal can never escalate into a search failure. Same-session call,
    so no extra login round-trip; UNSUBSCRIBE is a session-level command
    and does not require a selected mailbox.
    '''
    try:
        client.unsubscribe_folder(folder.replace('/', '.'))
        print(f"[search_envelopes] removed stale subscription for {folder!r}")
    except IMAPClientError as exc:
        print(f"[search_envelopes] failed to unsubscribe {folder!r}: {exc}")


def _triples_for(client, folder, uids, want_attachment):
    '''Fetches INTERNALDATE (and BODYSTRUCTURE when filtering attachments) for
    `uids` in the currently-selected `folder` and returns a list of
    (date, folder, uid) triples.'''
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

    triples = []
    for u in uids:
        data = meta.get(u)
        if not data:
            continue
        idate = data.get(b'INTERNALDATE')
        if idate is None:
            continue
        triples.append((idate.date(), folder, u))
    return triples


def apply_cursor(triples, cursor):
    '''Drops everything in `triples` that the previous page already returned.'''
    if cursor is None:
        return triples
    cur_d = datetime.date.fromisoformat(cursor['last_date'])
    cur_f = cursor['last_folder']
    cur_u = int(cursor['last_uid'])
    return [t for t in triples if (t[0], t[1], t[2]) < (cur_d, cur_f, cur_u)]


def build_next_cursor(remaining, page):
    '''Encodes the next-page cursor from the tail of `page`, or returns None
    when `page` already exhausts `remaining`.'''
    if not page or len(remaining) <= len(page):
        return None
    last_d, last_f, last_u = page[-1]
    return encode_cursor({
        'last_date': last_d.isoformat(),
        'last_folder': last_f,
        'last_uid': int(last_u),
    })


def fetch_envelopes_grouped(client, triples):
    '''Hydrates `triples` into envelope dicts, preserving the input order.

    Groups by folder and SELECTs each one in turn before fetching, so cross-
    folder results pay one extra SELECT per unique folder per page rather
    than per envelope. Single-folder results pay one SELECT (the folder
    is already selected from `search_folders`, but a defensive re-select
    is cheap).
    '''
    if not triples:
        return []
    by_folder = {}
    for index, (_date, folder, uid) in enumerate(triples):
        by_folder.setdefault(folder, []).append((index, uid))
    results = [None] * len(triples)
    for folder, items in by_folder.items():
        ids = [uid for _, uid in items]
        client.select_folder(folder.replace('/', '.'), readonly=True)
        fetched = client.fetch(ids, ENVELOPE_FETCH_KEYS)
        for index, uid in items:
            data = fetched.get(uid)
            if data is None:
                continue
            env = envelope_dict(uid, data)
            env['folder'] = folder
            results[index] = env
    return [r for r in results if r is not None]


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
    if not isinstance(payload, dict):
        raise ValueError('invalid cursor')
    for key in ('last_date', 'last_folder', 'last_uid'):
        if key not in payload:
            raise ValueError('invalid cursor')
    try:
        datetime.date.fromisoformat(payload['last_date'])
        int(payload['last_uid'])
    except (TypeError, ValueError) as exc:
        raise ValueError('invalid cursor') from exc
    if not isinstance(payload['last_folder'], str) or not payload['last_folder']:
        raise ValueError('invalid cursor')
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


def _safe_logout(client):
    '''Closes the IMAP session, tolerating a connection that has already died.

    The IMAP server can drop the TCP session out from under us (idle reap on
    the NLB after a long search, a Dovecot-side restart, a server-side
    connection limit). When that happens, `client.logout()` tries to send
    LOGOUT down a dead socket and `imaplib` raises `IMAP4.abort: socket
    error: EOF`. Letting that escape from `finally` either turns a successful
    search into a 502 (when the try body completed) or masks the original
    exception from the try body (when something else failed first). Neither
    is helpful, so the cleanup failure is logged and swallowed -- the work
    the caller asked for has either succeeded or failed independently of
    whether we say goodbye politely.
    '''
    try:
        client.logout()
    except Exception as exc: # pylint: disable=broad-except
        print(f"[search_envelopes] logout failed (connection likely already closed): {exc}")
