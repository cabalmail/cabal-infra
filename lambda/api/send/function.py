'''Sends an email message'''
import copy
import json
import re
import smtplib
import time
import uuid
from email.message import EmailMessage
from email.utils import formatdate, getaddresses
import boto3 # pylint: disable=import-error
from botocore.exceptions import ClientError # pylint: disable=import-error
from helper import get_imap_client # pylint: disable=import-error
from helper import get_mpw # pylint: disable=import-error
from helper import get_object # pylint: disable=import-error
from helper import upload_object # pylint: disable=import-error
from helper import user_authorized_for_sender # pylint: disable=import-error
from helper import MaintenanceError, maintenance_response # pylint: disable=import-error

# Sending is SMTP-first: outbound delivery never blocks on IMAP. The Bcc-free
# Sent copy is staged to S3 and queued, and the append_sent consumer Lambda
# writes it to the Sent folder when IMAP is available (immediately in steady
# state, after the roll completes during an IMAP deploy). See
# docs (lambda/api/append_sent/function.py).
APPEND_SENT_QUEUE = 'cabal-append-sent'
SENT_PENDING_PREFIX = 'sent-pending'

# Dedupe window for /send. SMTP-first means a lost response that a client (or
# the Apple SendQueue) retries could otherwise deliver twice; we claim the
# Message-Id in cabal-rate-limits (TTL attribute `expires_at`) before SMTP and
# release it if SMTP fails. The window only needs to outlast a client retry.
DEDUPE_TABLE = 'cabal-rate-limits'
SEND_DEDUPE_TTL = 600

sqs = boto3.client('sqs')
ddb = boto3.resource('dynamodb')
_dedupe_table = ddb.Table(DEDUPE_TABLE)
_queue_url_cache = {}

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
ALLOWED_KEY_PREFIX = 'outbound'
# Matches `outbound/<user>/<uuid>/<filename>` keys minted by upload_url.
# The user segment must equal the authenticated caller; we still pin the
# overall shape here so a malformed key is rejected before any S3 call.
_KEY_SHAPE = re.compile(r'^outbound/([^/]+)/[^/]+/[^/]+$')

def handler(event, _context):
    '''Sends an email message'''

    body = json.loads(event['body'])
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    # Pin the sender to the exact validated address and reuse that same string
    # as the SMTP MAIL FROM below, so a display-name game in the From header
    # cannot leave the envelope sender and the visible From disagreeing.
    sender = body['sender']
    if not user_authorized_for_sender(user, sender):
        return {
            "statusCode": 500,
            "body": json.dumps({
                "status": "Sender address not associated with authenticated user"
            })
        }

    bucket = body['host'].replace('imap', 'cache')
    try:
        validate_outbound_headers(body)
        attachments = load_attachments(body.get('attachments', []), bucket, user)
    except ValueError as err:
        return {
            "statusCode": 400,
            "body": json.dumps({
                "status": str(err)
            })
        }

    msg = compose_message(body['subject'], sender, {
                            "to": ','.join(body['to_list']),
                            "cc": ','.join(body['cc_list']),
                            "bcc": ','.join(body['bcc_list']),
                            "message_id": body['other_headers']['message_id'],
                            "in_reply_to": body['other_headers']['in_reply_to'],
                            "references": body['other_headers']['references']
                          },
                          body['text'], body['html'], attachments)

    if body.get('draft'):
        return _save_draft(body['host'], user, msg)

    # Non-draft: SMTP-first. Delivery must not block on IMAP (the IMAP tier is
    # single-task and has a zero-task window on every redeploy), so we send over
    # SMTP first and queue the Sent copy for the append_sent consumer to write
    # when IMAP is available.
    #
    # The Sent copy must not retain Bcc - it would expose blind recipients to
    # anyone who can read Sent. SMTP still delivers to the BCC addresses because
    # the recipient list is passed to send() explicitly.
    sent_copy = strip_bcc(msg)
    message_id = msg['Message-Id']

    # Idempotency: claim the Message-Id before SMTP so a retried /send (e.g. the
    # client never saw our response) cannot deliver twice. A duplicate claim
    # means we already delivered this exact message; report success so the
    # client stops retrying.
    if message_id and not _claim_send(message_id):
        return {
            "statusCode": 200,
            "body": json.dumps({
                "status": "submitted"
            })
        }

    recipients = [
        addr for _, addr in
        getaddresses(body['to_list'] + body['cc_list'] + body['bcc_list'])
        if addr
    ]

    return_from_send = send(msg, body['smtp_host'], sender, recipients)
    if return_from_send['statusCode'] != 200:
        # Delivery failed, so release the claim - the user's retry must be
        # allowed to actually send.
        if message_id:
            _release_send(message_id)
        return return_from_send

    # Delivered. Queue the Bcc-free Sent copy (best effort; a queue failure here
    # loses only the Sent record, not the delivery).
    _queue_sent_copy(sent_copy, body['host'], user, message_id)

    return {
        "statusCode": 200,
        "body": json.dumps({
            "status": "submitted"
        })
    }


def _save_draft(host, user, msg):
    '''Saves a draft to the user's Drafts folder. Drafts keep Bcc (the user is
    still composing). Interactive and IMAP-only, so during a planned IMAP roll
    there is nothing to queue - return the maintenance signal and let the client
    retry rather than failing.'''
    try:
        client = get_imap_client(host, user, 'INBOX')
    except MaintenanceError as err:
        return maintenance_response(err.state)
    append_drafts(msg, client)
    client.logout()
    return {
        "statusCode": 200,
        "body": json.dumps({
            "status": "saved"
        })
    }


def _append_sent_queue_url():
    '''Resolves (and caches) the append_sent SQS queue URL by name, so the
    shared call-module env does not have to carry a per-function variable.'''
    url = _queue_url_cache.get('url')
    if url is None:
        url = sqs.get_queue_url(QueueName=APPEND_SENT_QUEUE)['QueueUrl']
        _queue_url_cache['url'] = url
    return url


def _queue_sent_copy(msg, host, user, message_id):
    '''Stages the Bcc-free Sent copy to S3 and enqueues an append job. Best
    effort: a failure means the message was delivered but its Sent copy is not
    recorded, which we log rather than surface as a send failure.'''
    bucket = host.replace('imap', 'cache')
    key = f'{SENT_PENDING_PREFIX}/{user}/{uuid.uuid4()}'
    try:
        upload_object(bucket, key, 'message/rfc822', msg.as_string().encode())
        sqs.send_message(
            QueueUrl=_append_sent_queue_url(),
            MessageBody=json.dumps({
                'bucket': bucket,
                'key': key,
                'user': user,
                'host': host,
                'message_id': message_id or '',
            })
        )
        return True
    except Exception as err:  # pylint: disable=broad-except
        print(f'[send] WARN failed to queue Sent copy ({key}): {err}')
        return False


def _claim_send(message_id):
    '''Conditionally claims a Message-Id in the dedupe table. Returns True if it
    was newly claimed, False if a claim already exists. Fails OPEN (returns True)
    on any non-conditional error so a dedupe-store hiccup never blocks a send.'''
    try:
        _dedupe_table.put_item(
            Item={
                'pk': f'senddedupe#{message_id}',
                'expires_at': int(time.time()) + SEND_DEDUPE_TTL,
            },
            ConditionExpression='attribute_not_exists(pk)'
        )
        return True
    except ClientError as err:
        if err.response['Error']['Code'] == 'ConditionalCheckFailedException':
            return False
        print(f'[send-dedupe] WARN claim failed, proceeding: {err}')
        return True


def _release_send(message_id):
    '''Drops a Message-Id claim so a retry after a failed SMTP send can proceed.'''
    try:
        _dedupe_table.delete_item(Key={'pk': f'senddedupe#{message_id}'})
    except ClientError as err:
        print(f'[send-dedupe] WARN release failed: {err}')

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
def compose_message(subject, sender, headers, text, html, attachments=None):
    """Create a message object"""
    msg = EmailMessage()
    msg['Subject'] = subject
    msg['From'] = sender
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

def strip_bcc(msg):
    """Returns a copy of msg with every Bcc header removed.

    Mirrors what smtplib.send_message does to its wire copy, applied here to
    the copy that lands in Outbox (and then Sent). EmailMessage.__delitem__
    rebinds the header list, so the original msg keeps its Bcc for the
    explicit recipient computation in the handler.
    """
    copied = copy.copy(msg)
    del copied['Bcc']
    return copied

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

def append_drafts(msg, client):
    """Appends an email message to the user's Drafts folder with the
    \\Draft flag set. Creates the folder if it does not exist (create-then-
    append) so a missing Drafts folder on a fresh mailbox does not fail the
    call."""
    try:
        client.create_folder('Drafts')
    except: # pylint: disable=bare-except
        pass
    client.append('Drafts', msg.as_string().encode(), flags=[rb"\Draft", rb"\Seen"])

def send(msg, smtp_host, from_addr, to_addrs):
    """Send the message.

    from_addr pins the SMTP MAIL FROM to the validated sender address and
    to_addrs is the explicit RCPT TO list (including BCC), so display-name
    games in the From/To/Cc headers cannot change who actually receives the
    mail or what envelope sender the relay sees. smtplib still strips Bcc from
    the transmitted DATA, so blind recipients stay blind on the wire.
    """
    smtp_client = smtplib.SMTP_SSL(smtp_host)
    status_code = 200
    body = {
        "status": "submitted"
    }
    try:
        smtp_client.login("master", get_mpw())
    except smtplib.SMTPHeloError:
        status_code = 500
        body = {
            "status": "SMTP server did not respond correctly to Helo"
        }
    except smtplib.SMTPAuthenticationError:
        status_code = 401
        body = {
            "status": "SMTP server did not accept our credentials"
        }
    except smtplib.SMTPNotSupportedError:
        # The AUTH command is not supported by the server.
        status_code = 501
        body = {
            "status": "Server does not support our auth type"
        }
    except smtplib.SMTPException:
        status_code = 500
        body = {
            "status": "Other SMTP exception while authenticating"
        }
    if status_code != 200:
        smtp_client.quit()
        return {
            "statusCode": status_code,
            "body": json.dumps(body)
        }
    try:
        smtp_client.send_message(msg, from_addr=from_addr, to_addrs=to_addrs)
    except smtplib.SMTPRecipientsRefused:
        status_code = 401
        body = {
            "status": "SMTP server rejected recipient list; mail not sent",
            "additionalInfo": smtplib.SMTPRecipientsRefused
        }
    except smtplib.SMTPHeloError:
        status_code = 500
        body = {
            "status": "SMTP server did not respond correctly to Helo"
        }
    except smtplib.SMTPSenderRefused:
        status_code = 401
        body = {
            "status": "SMTP server rejected the sender"
        }
    except smtplib.SMTPDataError:
        status_code = 500
        body = {
            "status": "SMTP server rejected us after accepting our sender and recipients"
        }
    except smtplib.SMTPNotSupportedError:
        status_code = 500
        body = {
            "status": "Other SMTP exception while sending"
        }
    smtp_client.quit()
    return {
        "statusCode": status_code,
        "body": json.dumps(body)
    }
