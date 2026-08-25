'''Sends an email message'''
import json
import smtplib
import time
import traceback
import uuid
from email.utils import getaddresses
import boto3 # pylint: disable=import-error
from botocore.exceptions import ClientError # pylint: disable=import-error
from compose import ( # pylint: disable=import-error
    COMPOSE_REQUIRED_FIELDS,
    DRAFTS_FOLDER,
    append_draft,
    compose_from_body,
    guarded_draft_expunge,
    require_fields,
    unauthorized_sender_response_or_none,
)
from helper import delete_object # pylint: disable=import-error
from helper import get_imap_client # pylint: disable=import-error
from helper import get_mpw # pylint: disable=import-error
from helper import parse_json_body # pylint: disable=import-error
from helper import upload_object # pylint: disable=import-error
from helper import validate_uid # pylint: disable=import-error
from helper import CACHE_BUCKET, SMTP_HOST # pylint: disable=import-error
from helper import MaintenanceError, maintenance_response # pylint: disable=import-error
import smtp_session # pylint: disable=import-error

# Sending is SMTP-first: outbound delivery never blocks on IMAP. The
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
    # Check every key this handler indexes before anything reads one, so a
    # payload missing (say) `sender` or `host` gets the same named 400 a
    # rejected value gets rather than a bodiless 502 (#895).
    try:
        require_fields(body, COMPOSE_REQUIRED_FIELDS + ('host',))
    except ValueError as err:
        return _invalid(err)
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
        return _invalid(err)

    if body.get('draft'):
        return _save_draft(body['host'], user, msg)

    # Non-draft: SMTP-first. Delivery must not block on IMAP (the IMAP tier is
    # single-task and has a zero-task window on every redeploy), so we send over
    # SMTP first and queue the Sent copy for the append_sent consumer to write
    # when IMAP is available.
    #
    # The Sent copy keeps Bcc on purpose: it is the sender's only record of
    # who they blind-copied, and only the mailbox owner can read Sent.
    # Blindness is enforced on the wire, not here - smtplib strips Bcc from
    # the transmitted DATA and send() passes the recipient list explicitly
    # (see send() below).
    message_id = msg['Message-Id']

    # Idempotency: claim the Message-Id before SMTP so a retried /send (e.g. the
    # client never saw our response) cannot deliver twice. What a duplicate
    # claim is worth depends on whether that earlier attempt ever reported a
    # delivery - see _duplicate_response.
    if message_id and not _claim_send(message_id):
        return _duplicate_response(message_id)

    # Everything between the claim and a confirmed handoff runs under the
    # claim, so anything that raises in here has to take the claim with it:
    # an orphaned claim makes the client's retry - the exact retry the
    # idempotency design exists to serve - match a delivery that never
    # happened and get back 200 "submitted" until the TTL expires (#909).
    # We have no 250 from the relay on this path, so releasing may let a
    # retry deliver twice; that is the same at-least-once bet every MTA
    # makes on a lost 250, and it beats telling the user we sent mail we
    # did not send.
    try:
        recipients = [
            addr for _, addr in
            getaddresses((body['to_list'] or []) + (body['cc_list'] or [])
                         + (body['bcc_list'] or []))
            if addr
        ]
        return_from_send = send(msg, SMTP_HOST, sender, recipients)
    except Exception:  # pylint: disable=broad-except
        if message_id:
            _release_send(message_id)
        # Log the traceback the unhandled exception used to leave in
        # CloudWatch, since the handler now answers instead of dying.
        print(f'[send] ERROR send failed under claim {message_id}:'
              f' {traceback.format_exc()}')
        return {
            "statusCode": 500,
            "body": json.dumps({
                "status": "Send failed; the message was not delivered"
            })
        }

    if return_from_send['statusCode'] != 200:
        # Delivery failed, so release the claim - the user's retry must be
        # allowed to actually send.
        if message_id:
            _release_send(message_id)
        return return_from_send

    # Delivered. Stamp the claim so a duplicate arriving inside the window can
    # be told the message really went out; a bare claim proves only that some
    # attempt started (#1019).
    if message_id:
        _confirm_send(message_id)

    # Queue the Sent copy (best effort; a queue failure here loses only the
    # Sent record, not the delivery).
    _queue_sent_copy(msg, body['host'], user, message_id)

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


def _invalid(err):
    '''Builds the 400 returned when a validator rejects the request.'''
    return {
        "statusCode": 400,
        "body": json.dumps({
            "status": str(err)
        })
    }


def _save_draft(host, user, msg):
    '''Saves a draft to the user's Drafts folder. Interactive and IMAP-only,
    so during a planned IMAP roll there is nothing to queue - return the
    maintenance signal and let the client retry rather than failing.

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
            delete_object(CACHE_BUCKET, f'{user}/{DRAFTS_FOLDER}/{uid}/raw')
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


def _queue_sent_copy(msg, _host, user, message_id):
    '''Stages the Sent copy to S3 and enqueues an append job. Best
    effort: a failure means the message was delivered but its Sent copy is not
    recorded, which we log rather than surface as a send failure.

    `_host` is ignored; the cache bucket is derived server-side (CACHE_BUCKET).'''
    bucket = CACHE_BUCKET
    key = f'{SENT_PENDING_PREFIX}/{user}/{uuid.uuid4()}'
    try:
        upload_object(bucket, key, 'message/rfc822', msg.as_string().encode())
        sqs.send_message(
            QueueUrl=_append_sent_queue_url(),
            MessageBody=json.dumps({
                'bucket': bucket,
                'key': key,
                'user': user,
                'message_id': message_id or '',
            })
        )
        return True
    except Exception as err:  # pylint: disable=broad-except
        print(f'[send] WARN failed to queue Sent copy ({key}): {err}')
        return False


def _claim_send(message_id):
    '''Conditionally claims a Message-Id in the dedupe table. Returns True if it
    was newly claimed or the prior claim has expired, False while a live claim
    exists. Fails OPEN (returns True) on any non-conditional error so a
    dedupe-store hiccup never blocks a send.

    The condition compares `expires_at` rather than trusting DynamoDB to have
    reaped the row: TTL deletion is best-effort (AWS documents it as typically
    within 48 hours), so an existence-only check made the claim block for as
    long as the row physically survived instead of the SEND_DEDUPE_TTL the
    constant advertises - measured at 192 s past expiry on stage (#1018).'''
    now = int(time.time())
    try:
        _dedupe_table.put_item(
            Item={
                'pk': f'senddedupe#{message_id}',
                'expires_at': now + SEND_DEDUPE_TTL,
            },
            ConditionExpression='attribute_not_exists(pk) OR #e < :now',
            ExpressionAttributeNames={'#e': 'expires_at'},
            ExpressionAttributeValues={':now': now}
        )
        return True
    except ClientError as err:
        if err.response['Error']['Code'] == 'ConditionalCheckFailedException':
            return False
        print(f'[send-dedupe] WARN claim failed, proceeding: {err}')
        return True


def _duplicate_response(message_id):
    '''Answers a request whose Message-Id is already claimed.

    Only a claim carrying the delivery marker proves the message went out.
    A claim without one is either still in flight or was orphaned by a
    handler that died mid-send (#909), and answering it with the same 200
    "submitted" a real delivery gets makes the two indistinguishable: the
    Apple SendQueue read that as proof and deleted the queued message
    without anything having been delivered (#1019). So an unconfirmed claim
    gets a 409 instead - the message is neither sent nor failed, and the
    client must keep it and retry once the claim clears (<= SEND_DEDUPE_TTL).'''
    if _claim_confirmed(message_id):
        return {
            "statusCode": 200,
            "body": json.dumps({
                "status": "submitted",
                "duplicate": True
            })
        }
    return {
        "statusCode": 409,
        "body": json.dumps({
            "status": "duplicate_in_flight",
            "message": "An earlier submission of this message is still in flight."
        })
    }


def _claim_confirmed(message_id):
    '''True when the live claim on this Message-Id carries the marker
    _confirm_send writes after the relay accepts the message.

    Fails CLOSED (returns False) on a read error: an unreadable claim is one
    we cannot prove delivered, and telling the client to retry costs at worst
    a duplicate once the claim expires - the same at-least-once bet the
    release-on-failure path already makes.'''
    try:
        response = _dedupe_table.get_item(
            Key={'pk': f'senddedupe#{message_id}'},
            ConsistentRead=True
        )
    except ClientError as err:
        print(f'[send-dedupe] WARN claim read failed, treating as unconfirmed: {err}')
        return False
    return bool((response.get('Item') or {}).get('delivered'))


def _confirm_send(message_id):
    '''Marks a claim delivered so a later duplicate can be told the truth.

    Best effort: a failure here only costs the duplicate a 409 and another
    retry, never a delivery. The attribute is aliased because a reserved-word
    ValidationException would land in the except below and disable the marker
    silently (#1018).'''
    try:
        _dedupe_table.update_item(
            Key={'pk': f'senddedupe#{message_id}'},
            UpdateExpression='SET #d = :true',
            ExpressionAttributeNames={'#d': 'delivered'},
            ExpressionAttributeValues={':true': True}
        )
    except ClientError as err:
        print(f'[send-dedupe] WARN delivery marker failed: {err}')


def _release_send(message_id):
    '''Drops a Message-Id claim so a retry after a failed SMTP send can proceed.'''
    try:
        _dedupe_table.delete_item(Key={'pk': f'senddedupe#{message_id}'})
    except ClientError as err:
        print(f'[send-dedupe] WARN release failed: {err}')

def send(msg, smtp_host, from_addr, to_addrs):
    """Send the message.

    from_addr pins the SMTP MAIL FROM to the validated sender address and
    to_addrs is the explicit RCPT TO list (including BCC), so display-name
    games in the From/To/Cc headers cannot change who actually receives the
    mail or what envelope sender the relay sees. smtplib still strips Bcc from
    the transmitted DATA, so blind recipients stay blind on the wire.
    """
    # smtp_session routes over the Cloud Map internal name when
    # SMTP_INTERNAL_HOST is set (private-submission cutover), falling back
    # to the public listener when it is not set or does not answer.
    #
    # The dial is guarded like every other step: a relay that is refusing
    # connections is the ordinary transient failure here, and it has to come
    # back as a non-200 the handler can release the claim on, not as an
    # exception out of the handler (#909). smtplib.SMTPException subclasses
    # OSError, as does ssl.SSLError.
    try:
        smtp_client = smtp_session.dial_smtp(smtp_host)
    except OSError as err:
        print(f'[send] ERROR could not dial SMTP relay {smtp_host}: {err}')
        return {
            "statusCode": 500,
            "body": json.dumps({
                "status": "Could not connect to the SMTP relay; mail not sent"
            })
        }
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
        _quiet_quit(smtp_client)
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
    _quiet_quit(smtp_client)
    return {
        "statusCode": status_code,
        "body": json.dumps(body)
    }


def _quiet_quit(smtp_client):
    '''Closes the SMTP connection without letting the close itself throw.

    By the time we quit, the outcome is already decided - and after a
    successful send_message the message is delivered. A QUIT that raises
    used to escape the handler, which (post-#909) would release the claim
    on a message the relay had already accepted and let a retry deliver it
    twice.'''
    try:
        smtp_client.quit()
    except OSError as err:
        print(f'[send] WARN SMTP quit failed: {err}')
