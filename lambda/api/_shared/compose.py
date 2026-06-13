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

# Attachments are uploaded to S3 via the /upload_url Lambda's presigned
# PUT URLs (the cache bucket's 2-day lifecycle handles cleanup). Total
# decoded payload is hard-capped well above the React/Apple soft warning
# at 20 MB so clients can present a friendly warning while a malformed
# or hostile request still hits a server-side ceiling.
MAX_TOTAL_ATTACHMENT_BYTES = 25 * 1024 * 1024
# Hard ceiling on attachment count per message (Phase 2 of
# docs/0.10.x/application-surface-hardening-plan.md). The React/Apple UIs
# never attach more than a handful; this bounds a hostile request whose
# individual parts each stay under the byte cap.
MAX_ATTACHMENTS = 10
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
    """
    if not raw:
        return []
    if not isinstance(raw, list):
        raise ValueError("attachments must be a list")
    if len(raw) > MAX_ATTACHMENTS:
        raise ValueError(f"at most {MAX_ATTACHMENTS} attachments per message")
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
    msg.set_content(text, subtype='plain')
    msg.add_alternative(html, subtype='html')
    for attachment in attachments or []:
        msg.add_attachment(
            attachment['data'],
            maintype=attachment['maintype'],
            subtype=attachment['subtype'],
            filename=attachment['filename'],
        )
    return msg


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
    bucket = body['host'].replace('imap', 'cache')
    validate_outbound_headers(body)
    attachments = load_attachments(body.get('attachments', []), bucket, user)
    # The visible From may carry the user's display-name preference, but the
    # address part is always the bare validated sender (which /send also pins
    # as the SMTP MAIL FROM).
    from_header = format_mailbox(sender_display_name(user), body['sender'])
    return compose_message(body['subject'], from_header, {
                             "to": ','.join(body['to_list']),
                             "cc": ','.join(body['cc_list']),
                             "bcc": ','.join(body['bcc_list']),
                             "message_id": body['other_headers']['message_id'],
                             "in_reply_to": body['other_headers']['in_reply_to'],
                             "references": body['other_headers']['references']
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
