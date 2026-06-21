'''Sends an email message'''
import copy
import json
import smtplib
import time
import uuid
from email.utils import getaddresses
import boto3 # pylint: disable=import-error
from botocore.exceptions import ClientError # pylint: disable=import-error
from compose import ( # pylint: disable=import-error
    DRAFTS_FOLDER,
    append_draft,
    compose_from_body,
    guarded_draft_expunge,
    unauthorized_sender_response_or_none,
)
from helper import delete_object # pylint: disable=import-error
from helper import get_imap_client # pylint: disable=import-error
from helper import get_mpw # pylint: disable=import-error
from helper import parse_json_body # pylint: disable=import-error
from helper import upload_object # pylint: disable=import-error
from helper import validate_uid # pylint: disable=import-error
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

def handler(event, _context):  # pylint: disable=too-many-return-statements
    '''Sends an email message'''

    body, error = parse_json_body(event)
    if error:
        return error
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    # Pin the sender to the exact validated address and reuse that same string
    # as the SMTP MAIL FROM below, so a display-name game in the From header
    # cannot leave the envelope sender and the visible From disagreeing.
    sender = body['sender']
    unauthorized = unauthorized_sender_response_or_none(user, sender)
    if unauthorized:
        return unauthorized

    try:
        msg = compose_from_body(body, user)
    except ValueError as err:
        return {
            "statusCode": 400,
            "body": json.dumps({
                "status": str(err)
            })
        }

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

    # Send-from-draft cleanup (best effort, same spirit as the Sent copy):
    # when the client passes the draft's coordinates, expunge the now-stale
    # server copy so it does not linger in Drafts after delivery.
    _discard_draft_copy(body, user)

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
    retry rather than failing.

    Create-only on purpose: this branch keeps its original response shape for
    the React explicit-save flow. /save_draft (which shares append_draft) is
    the lifecycle-aware endpoint that returns the new copy's UIDPLUS
    coordinates and can replace or discard a prior copy.'''
    try:
        client = get_imap_client(host, user, 'INBOX')
    except MaintenanceError as err:
        return maintenance_response(err.state)
    append_draft(client, msg)
    client.logout()
    return {
        "statusCode": 200,
        "body": json.dumps({
            "status": "saved"
        })
    }


def _discard_draft_copy(body, user):
    '''Best-effort removal of the server-side draft copy after a successful
    send-from-draft. The expunge is UIDVALIDITY-guarded and Drafts-scoped;
    any failure (including a planned IMAP roll) is logged rather than
    surfaced - the message has already been delivered, and the worst outcome
    is a stale draft copy the user can delete by hand.'''
    if body.get('discard_draft_uid') is None:
        return
    try:
        uid = validate_uid(body.get('discard_draft_uid'))
        uidvalidity = validate_uid(body.get('discard_draft_uidvalidity'))
        client = get_imap_client(body['host'], user, 'INBOX')
        try:
            expunged = guarded_draft_expunge(client, uid, uidvalidity)
        finally:
            client.logout()
        if expunged:
            # Drop the cached raw body so the expunged draft is not
            # retrievable from the cache bucket afterwards (same hygiene as
            # purge_messages).
            bucket = body['host'].replace('imap', 'cache')
            delete_object(bucket, f'{user}/{DRAFTS_FOLDER}/{uid}/raw')
    except Exception as err:  # pylint: disable=broad-except
        print(f'[send] WARN failed to discard draft copy: {err}')


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
