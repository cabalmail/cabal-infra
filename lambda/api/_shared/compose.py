'''Shared outbound-message composition and Drafts-folder lifecycle helpers.

Split out of send/function.py when /save_draft landed (Phase 3 of
docs/0.10.x/draft-sync-and-threading-headers-plan.md) so /send and
/save_draft validate, compose, and store drafts through the same code.
Everything here is IMAP/MIME-shaped; SMTP delivery, the Sent-copy queue,
and send dedupe stay in send/function.py.
'''
import json
import os
import re
from email.message import EmailMessage
from email.utils import formatdate
import boto3 # pylint: disable=import-error
from botocore.exceptions import ClientError # pylint: disable=import-error
from helper import format_mailbox # pylint: disable=import-error
from helper import get_object # pylint: disable=import-error
from helper import user_authorized_for_sender # pylint: disable=import-error
from helper import validate_content_id # pylint: disable=import-error
from helper import CACHE_BUCKET # pylint: disable=import-error

# Attachments are uploaded to S3 via the /upload_url Lambda's presigned
# PUT URLs (the cache bucket's 2-day lifecycle handles cleanup). Total
# decoded payload is hard-capped well above the React/Apple soft warning
# at 20 MB so clients can present a friendly warning while a malformed
# or hostile request still hits a server-side ceiling.
MAX_TOTAL_ATTACHMENT_BYTES = 25 * 1024 * 1024
# There is deliberately no cap on attachment *count*. Phase 2 of
# docs/0.10.x/application-surface-hardening-plan.md set one at 10 on the
# premise that "the React/Apple UIs never attach more than a handful";
# uncapping the iOS photo picker retired that premise, and a count is the
# wrong axis anyway — what a recipient's server rejects is total message
# size, which MAX_TOTAL_ATTACHMENT_BYTES above already bounds. The residual
# cost of a bundle of many tiny parts is one S3 GET each, from a caller who
# is already authenticated and could spend the same budget on repeat sends.
# Matches `outbound/<user>/<uuid>/<filename>` keys minted by upload_url.
# The user segment must equal the authenticated caller; we still pin the
# overall shape here so a malformed key is rejected before any S3 call.
_KEY_SHAPE = re.compile(r'^outbound/([^/]+)/[^/]+/[^/]+$')

# Every draft operation is pinned to this folder, mirroring the
# trash-scoping of purge_messages / empty_trash: no request parameter can
# aim a draft expunge at another mailbox.
DRAFTS_FOLDER = 'Drafts'
# UIDPLUS response code carried on a successful APPEND (RFC 4315):
# `[APPENDUID <uidvalidity> <uid>]`.
_APPENDUID_RE = re.compile(r'\[APPENDUID (\d+) (\d+)\]')

# The body keys compose_from_body indexes directly. A message cannot be
# built without them, so their absence is a client error -- but only if it
# is checked, because an escaping KeyError becomes a bodiless 502 rather
# than the 400 the handlers already have for a rejected payload (#895).
COMPOSE_REQUIRED_FIELDS = ('sender', 'subject', 'to_list', 'cc_list',
                           'bcc_list', 'text', 'html')

# The recipient keys the composer joins and /send re-reads for the SMTP
# envelope. Presence is not enough for these: a string where a list belongs
# gets past every presence and CR/LF check and only fails downstream, where
# the failure is a TypeError rather than a rejected payload (#909).
RECIPIENT_LIST_FIELDS = ('to_list', 'cc_list', 'bcc_list')

# The other_headers keys the composer indexes and joins. Same reasoning as
# RECIPIENT_LIST_FIELDS, with a worse failure: a string here passes every
# presence and CR/LF check (the injection validator iterates it character by
# character, and each single character is clean), then `[0]` degenerates the
# composed Message-Id to the string's first character. /send claims that
# header as its dedupe key, so every string-shaped request claims the same
# key and each one after the first is silently discarded behind a
# 200 "submitted" (#1013).
THREADING_LIST_FIELDS = ('message_id', 'in_reply_to', 'references')

# The user's display-name preference (set via /set_preferences) becomes the
# From header's display name. It is read server-side - never from the request
# body - so a client cannot put an arbitrary name on the wire per message.
PREFERENCES_TABLE = os.environ.get('USER_PREFERENCES_TABLE_NAME', 'cabal-user-preferences')
_preferences_table = boto3.resource('dynamodb').Table(PREFERENCES_TABLE)


def sender_display_name(user):
    '''Returns the user's display-name preference, or empty string.

    Fails open: any lookup problem means the From header simply omits the
    display name rather than blocking the send. Control characters are
    rejected here as well as at write time (set_preferences) so a stored
    name can never smuggle headers into the composed message.

    A future per-address override would resolve here: the sender's row in
    cabal-addresses (already fetched by user_authorized_for_sender) would
    take precedence over this user-level preference.
    '''
    try:
        item = _preferences_table.get_item(Key={'user': user}).get('Item', {})
    except ClientError as err:
        print(f'[compose] WARN display-name lookup failed: {err}')
        return ''
    name = item.get('name', '')
    if not isinstance(name, str):
        return ''
    name = name.strip()
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in name):
        return ''
    return name


def load_attachments(raw, bucket, user):
    """Resolve attachment references against S3 and validate the bundle.

    Each entry must carry `filename`, `mime_type`, and an `s3_key` minted
    by /upload_url. The key's user segment is checked against the
    authenticated caller so a request can't pull from another user's
    upload prefix. Total fetched size is capped above the client-side
    warning threshold as a defensive ceiling.

    An entry may also carry `content_id`, the bare id (no angle brackets)
    an `<img src="cid:...">` in the HTML body names: compose_message then
    sends the image inline rather than attached. It is passed through
    unchecked; compose_message decides whether it can be honoured.
    """
    if not raw:
        return []
    if not isinstance(raw, list):
        raise ValueError("attachments must be a list")
    decoded = []
    total = 0
    for index, entry in enumerate(raw):
        if not isinstance(entry, dict):
            raise ValueError(f"attachment {index} is not an object")
        filename = entry.get('filename')
        mime_type = entry.get('mime_type') or 'application/octet-stream'
        s3_key = entry.get('s3_key')
        if not filename or not isinstance(filename, str):
            raise ValueError(f"attachment {index} is missing a filename")
        if not s3_key or not isinstance(s3_key, str):
            raise ValueError(f"attachment {index} is missing s3_key")
        match = _KEY_SHAPE.match(s3_key)
        if not match or match.group(1) != user:
            raise ValueError(
                f"attachment {index} ({filename}) has an invalid s3_key"
            )
        try:
            data = get_object(bucket, s3_key)
        except Exception as err: # pylint: disable=broad-except
            raise ValueError(
                f"attachment {index} ({filename}) could not be fetched from staging"
            ) from err
        total += len(data)
        if total > MAX_TOTAL_ATTACHMENT_BYTES:
            raise ValueError(
                "attachments exceed the "
                f"{MAX_TOTAL_ATTACHMENT_BYTES // (1024 * 1024)} MB total limit"
            )
        if '/' in mime_type:
            maintype, subtype = mime_type.split('/', 1)
        else:
            maintype, subtype = 'application', 'octet-stream'
        decoded.append({
            'filename': filename,
            'maintype': maintype,
            'subtype': subtype,
            'data': data,
            'content_id': entry.get('content_id'),
        })
    return decoded


# pylint: disable=too-many-arguments,too-many-positional-arguments
def compose_message(subject, from_header, headers, text, html, attachments=None):
    """Create a message object. from_header is a full RFC 5322 mailbox
    (optionally carrying a display name); the bare envelope sender is pinned
    separately in the handler."""
    msg = EmailMessage()
    msg['Subject'] = subject
    msg['From'] = from_header
    if len(headers['to']):
        msg['To'] = headers['to']
    if len(headers['cc']):
        msg['Cc'] = headers['cc']
    if len(headers['bcc']):
        msg['Bcc'] = headers['bcc']
    if len(headers['message_id']):
        msg['Message-Id'] = headers['message_id'][0]
    if len(headers['in_reply_to']):
        msg['In-Reply-To'] = headers['in_reply_to'][0]
    if len(headers['references']):
        msg['References'] = ' '.join(headers['references'])
    msg['Date'] = formatdate(localtime=True)
    _set_body(msg, text, html)
    inline = _add_inline_images(msg, html, attachments or [])
    for index, attachment in enumerate(attachments or []):
        if index in inline:
            continue
        msg.add_attachment(
            attachment['data'],
            maintype=attachment['maintype'],
            subtype=attachment['subtype'],
            filename=attachment['filename'],
        )
    return msg


def _add_inline_images(msg, html, attachments):
    """Sends each image the HTML body shows by Content-ID inline, beside
    the HTML in a multipart/related (RFC 2387), and returns the indices of
    the entries it took.

    An entry goes inline only when its `content_id` is a valid Content-ID
    once bracketed (helper.validate_content_id, the check /fetch_inline_image
    applies when a reader asks for the part) that the header can carry
    literally (MAX_INLINE_CONTENT_ID_LEN), it is an image, the message
    has an HTML body, an `src` attribute in that body names `cid:<id>`, and
    no earlier entry claimed the same id. Anything else stays an ordinary
    attachment, as every entry was before inline images: a forwarded or
    resumed part may carry its original sender's id, and refusing the send
    over it would lose more than attaching it does.
    """
    if not html.strip():
        return set()
    related = None
    taken = set()
    claimed = set()
    for index, attachment in enumerate(attachments):
        content_id = attachment.get('content_id')
        if (attachment['maintype'] != 'image' or not isinstance(content_id, str)
                or content_id in claimed or not _is_valid_content_id(content_id)
                or not _html_shows(html, content_id)):
            continue
        if related is None:
            related = msg.get_body(('html',))
        # A filename alone would make the part an attachment; the explicit
        # disposition keeps it inline.
        related.add_related(
            attachment['data'],
            maintype=attachment['maintype'],
            subtype=attachment['subtype'],
            cid=f'<{content_id}>',
            disposition='inline',
            filename=attachment['filename'],
        )
        claimed.add(content_id)
        taken.add(index)
    if related is not None:
        # RFC 2387 requires the root part's type; the stdlib leaves it out.
        related.set_param('type', 'text/html')
    return taken


# The longest bare id a Content-ID header carries literally. The stdlib
# treats Content-ID as unstructured text: an `<id>` that fits no 78-column
# line on its own, or that holds a non-ASCII byte or an `=?`, it rewrites
# as RFC 2047 encoded-words, which a msg-id may not contain (RFC 2047
# section 5) and which other mail clients then fail to match against the
# HTML's `cid:`. Up to this length the id stays literal, folded onto a
# continuation line of its own at worst.
MAX_INLINE_CONTENT_ID_LEN = 75


def _is_valid_content_id(content_id):
    """Whether `content_id` (bare) is a Content-ID a reader can fetch and
    the header can carry as written."""
    if (len(content_id) > MAX_INLINE_CONTENT_ID_LEN or not content_id.isascii()
            or '=?' in content_id):
        return False
    try:
        validate_content_id(f'<{content_id}>')
    except ValueError:
        return False
    return True


def _html_shows(html, content_id):
    """Whether an `src` attribute in `html` names `cid:<content_id>`.

    The attribute, not the text: plain text that mentions a `cid:` (as a
    quoted Outlook message's `[cid:image001.png@...]` does) shows nothing.
    """
    pattern = (r'(?i:src)\s*=\s*(["\'])(?i:cid):' + re.escape(content_id)
               + r'\1')
    return re.search(pattern, html) is not None


def _set_body(msg, text, html):
    """Writes the body: multipart/alternative when both halves carry
    content, otherwise one part holding whichever half does.

    Clients send both keys, and this used to wrap them as alternatives
    unconditionally. An empty half is not another rendering of the message,
    but a reader cannot tell: it shows the last part it can render, so a
    message whose `html` arrived empty displayed as a blank body over the
    text the sender wrote. The tester's direct-API /send (`"html": ""`)
    delivered exactly that, and so would a client whose HTML conversion
    failed on the way here. Whitespace counts as empty, since it renders as
    nothing too; a message with neither half is one empty text/plain part.
    """
    if html.strip() and not text.strip():
        msg.set_content(html, subtype='html')
        return
    msg.set_content(text, subtype='plain')
    if html.strip():
        msg.add_alternative(html, subtype='html')


def unauthorized_sender_response_or_none(user, sender):
    '''Returns the 500 response /send has always used when the sender address
    is not associated with the authenticated caller, or None when authorized.
    Shared by /send and /save_draft so both endpoints gate composition on the
    same check with the same wire shape.'''
    if user_authorized_for_sender(user, sender):
        return None
    return {
        "statusCode": 500,
        "body": json.dumps({
            "status": "Sender address not associated with authenticated user"
        })
    }


def compose_from_body(body, user):
    '''Builds the outbound EmailMessage from a /send-shaped request body:
    header-injection validation, attachment staging from S3, display-name
    lookup, and MIME assembly. Raises ValueError on a rejected payload
    (callers translate it to a 400). Sender authorization is the caller's
    responsibility (see unauthorized_sender_response_or_none).'''
    bucket = CACHE_BUCKET
    require_fields(body, COMPOSE_REQUIRED_FIELDS)
    require_list_fields(body, RECIPIENT_LIST_FIELDS)
    require_other_header_lists(body)
    validate_outbound_headers(body)
    attachments = load_attachments(body.get('attachments', []), bucket, user)
    # The visible From may carry the user's display-name preference, but the
    # address part is always the bare validated sender (which /send also pins
    # as the SMTP MAIL FROM).
    from_header = format_mailbox(sender_display_name(user), body['sender'])
    # The threading headers are read the same defensive way
    # validate_outbound_headers reads them: absent means no threading
    # context, which is exactly what a fresh (non-reply) compose has.
    # Hard-indexing them here made the two halves of one request disagree
    # -- optional to the validator, required five lines later -- and the
    # KeyError escaped as a bodiless 502 (#895).
    others = body.get('other_headers', {}) or {}
    # Same defensiveness for the recipient lists: the validator above reads
    # each as `... or []`, so a null list is a payload it accepts and this
    # must not then die on `','.join(None)`.
    return compose_message(body['subject'], from_header, {
                             "to": ','.join(body['to_list'] or []),
                             "cc": ','.join(body['cc_list'] or []),
                             "bcc": ','.join(body['bcc_list'] or []),
                             "message_id": others.get('message_id', []) or [],
                             "in_reply_to": others.get('in_reply_to', []) or [],
                             "references": others.get('references', []) or []
                           },
                           body['text'], body['html'], attachments)


def _reject_crlf(value, field):
    """Raises ValueError if a header value carries a CR or LF.

    Embedded line breaks are how header injection smuggles extra headers; we
    reject them outright rather than trust EmailMessage's uneven per-field
    validation to fold or drop them.
    """
    if not isinstance(value, str):
        return
    if '\r' in value or '\n' in value:
        raise ValueError(f"{field} contains illegal line breaks")


def require_fields(body, fields):
    """Raises ValueError naming every required body key the request omits.

    Callers translate the ValueError to a 400, which is the point: without
    this the handlers index the key anyway and the KeyError escapes as a
    bodiless 502 (#895). Presence only - a supplied value still has to get
    past validate_outbound_headers.
    """
    missing = [field for field in fields if field not in body]
    if missing:
        raise ValueError(f"missing required field(s): {', '.join(missing)}")


def require_list_fields(body, fields):
    """Raises ValueError naming a field whose value is not a list of strings.

    Shape, not presence: `require_fields` above catches an omitted key, and
    `validate_outbound_headers` catches a hostile value, but neither notices
    that `to_list` arrived as the bare string an unfamiliar client might send.
    That payload composed a header of comma-separated characters and then blew
    up in /send's `getaddresses((body['to_list'] or []) + ...)` with a
    TypeError, which escaped as a bodiless 502 (#909). It is a client error,
    so it gets the same named 400 every other rejected payload gets.
    """
    for field in fields:
        _require_string_list(body.get(field), field, 'addresses', 'address')


def require_other_header_lists(body):
    """Raises ValueError naming an other_headers field with the wrong shape.

    The threading headers get the same shape check the recipient lists got in
    #909, because they reach a worse place when they are wrong: a bare string
    Message-Id composes as its own first character and then poisons /send's
    dedupe key for every later string-shaped request (#1013). Rejecting it as
    a named 400 puts the threading headers on the same footing as `to_list`.

    `other_headers` itself is read the composer's way (`... or {}`), so an
    omitted key, `null`, and `{}` all keep meaning "nothing to thread
    against" (#895); only a present, non-object value is a client error.
    """
    others = body.get('other_headers') or {}
    if not isinstance(others, dict):
        raise ValueError("other_headers must be an object")
    for field in THREADING_LIST_FIELDS:
        _require_string_list(others.get(field), f"other_headers.{field}",
                             'header values', 'header')


def _require_string_list(value, label, plural, singular):
    """Raises ValueError unless `value` is None or a list of strings.

    `None` is deliberately allowed everywhere this is used: the composer and
    the header validator both read these as `... or []`, so a null list is an
    accepted payload meaning "this field carries nothing" (#895).
    """
    if value is None:
        return
    if not isinstance(value, list):
        raise ValueError(f"{label} must be a list of {plural}")
    for entry in value:
        if not isinstance(entry, str):
            raise ValueError(f"{label} must contain only {singular} strings")


def validate_outbound_headers(body):
    """Validates caller-supplied header values for header injection.

    Checks subject, every recipient entry, message-id, in-reply-to, and each
    references token for embedded CR/LF. Raises ValueError (-> 400) on the
    first offending value.
    """
    _reject_crlf(body.get('subject'), 'subject')
    for field, label in (('to_list', 'to'), ('cc_list', 'cc'), ('bcc_list', 'bcc')):
        for entry in body.get(field, []) or []:
            _reject_crlf(entry, label)
    others = body.get('other_headers', {}) or {}
    for mid in others.get('message_id', []) or []:
        _reject_crlf(mid, 'message_id')
    for irt in others.get('in_reply_to', []) or []:
        _reject_crlf(irt, 'in_reply_to')
    for ref in others.get('references', []) or []:
        _reject_crlf(ref, 'references')


def append_draft(client, msg):
    """Appends an email message to the user's Drafts folder with the
    \\Draft flag set. Creates the folder if it does not exist (create-then-
    append) so a missing Drafts folder on a fresh mailbox does not fail the
    call. Returns (uidvalidity, uid) parsed from the UIDPLUS APPENDUID
    response code, or (None, None) when the code cannot be parsed."""
    try:
        client.create_folder(DRAFTS_FOLDER)
    except: # pylint: disable=bare-except
        pass
    response = client.append(DRAFTS_FOLDER, msg.as_string().encode(),
                             flags=[rb"\Draft", rb"\Seen"])
    return parse_appenduid(response)


def parse_appenduid(response):
    '''Extracts (uidvalidity, uid) from an APPEND response's UIDPLUS
    `[APPENDUID <uidvalidity> <uid>]` code. Tolerates the bytes/str/list
    shapes imapclient may hand back; returns (None, None) when absent.'''
    if isinstance(response, (list, tuple)):
        response = b' '.join(
            part if isinstance(part, bytes) else str(part).encode()
            for part in response if part is not None
        )
    if isinstance(response, bytes):
        response = response.decode(errors='replace')
    match = _APPENDUID_RE.search(str(response))
    if not match:
        return (None, None)
    return (int(match.group(1)), int(match.group(2)))


def guarded_draft_expunge(client, uid, uidvalidity):
    '''Flags `uid` \\Deleted and UID-EXPUNGEs it from the Drafts folder, but
    only when the folder's current UIDVALIDITY matches `uidvalidity`. Returns
    True when the message was expunged, False when the guard declined.

    The guard means a mailbox reset (UIDVALIDITY bump) can never expunge the
    wrong message: callers keep both copies and report the miss rather than
    guessing. Drafts-only by design - no parameter selects the folder.'''
    select_info = client.select_folder(DRAFTS_FOLDER)
    current = select_info.get(b'UIDVALIDITY')
    if current is None or int(current) != int(uidvalidity):
        return False
    client.delete_messages([uid])
    # UID EXPUNGE (Dovecot supports UIDPLUS), so only the requested draft is
    # removed even if other messages carry \Deleted.
    client.expunge([uid])
    return True
