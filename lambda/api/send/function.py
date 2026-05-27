'''Sends an email message'''
import json
import re
import smtplib
from email.message import EmailMessage
from email.utils import formatdate
from helper import get_imap_client # pylint: disable=import-error
from helper import get_mpw # pylint: disable=import-error
from helper import get_object # pylint: disable=import-error
from helper import user_authorized_for_sender # pylint: disable=import-error

# Attachments are uploaded to S3 via the /upload_url Lambda's presigned
# PUT URLs (the cache bucket's 2-day lifecycle handles cleanup). Total
# decoded payload is hard-capped well above the React/Apple soft warning
# at 20 MB so clients can present a friendly warning while a malformed
# or hostile request still hits a server-side ceiling.
MAX_TOTAL_ATTACHMENT_BYTES = 25 * 1024 * 1024
ALLOWED_KEY_PREFIX = 'outbound'
# Matches `outbound/<user>/<uuid>/<filename>` keys minted by upload_url.
# The user segment must equal the authenticated caller; we still pin the
# overall shape here so a malformed key is rejected before any S3 call.
_KEY_SHAPE = re.compile(r'^outbound/([^/]+)/[^/]+/[^/]+$')

def handler(event, _context):
    '''Sends an email message'''

    body = json.loads(event['body'])
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    if not user_authorized_for_sender(user, body['sender']):
        return {
            "statusCode": 500,
            "body": json.dumps({
                "status": "Sender address not associated with authenticated user"
            })
        }

    bucket = body['host'].replace('imap', 'cache')
    try:
        attachments = load_attachments(body.get('attachments', []), bucket, user)
    except ValueError as err:
        return {
            "statusCode": 400,
            "body": json.dumps({
                "status": str(err)
            })
        }

    msg = compose_message(body['subject'], body['sender'], {
                            "to": ','.join(body['to_list']),
                            "cc": ','.join(body['cc_list']),
                            "bcc": ','.join(body['bcc_list']),
                            "message_id": body['other_headers']['message_id'],
                            "in_reply_to": body['other_headers']['in_reply_to'],
                            "references": body['other_headers']['references']
                          },
                          body['text'], body['html'], attachments)

    client = get_imap_client(body['host'], user, 'INBOX')

    if body.get('draft'):
        append_drafts(msg, client)
        client.logout()
        return {
            "statusCode": 200,
            "body": json.dumps({
                "status": "saved"
            })
        }

    msg_id = append_outbox(msg, client)

    return_from_send = send(msg, body['smtp_host'])
    if return_from_send['statusCode'] != 200:
        return return_from_send

    if not move(msg_id, client):
        return {
            "statusCode": 500,
            "body": json.dumps({
                "status": "Send succeeded, but failed to move message from Outbox to Sent"
            })
        }
    client.logout()
    return {
        "statusCode": 200,
        "body": json.dumps({
            "status": "submitted"
        })
    }

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

def append_outbox(msg, client):
    """Appends an email message to Outbox"""
    try:
        client.create_folder('Outbox')
    except: # pylint: disable=bare-except
        pass
    msg_id = int(
                  str(
                      client.append('Outbox',msg.as_string().encode())
                  ).split(']', maxsplit=1)[0].rsplit(' ', maxsplit=1)[-1]
              )
    client.select_folder('Outbox')
    client.add_flags([msg_id], [rb"\Seen"], True)
    return msg_id

def append_drafts(msg, client):
    """Appends an email message to the user's Drafts folder with the
    \\Draft flag set. Creates the folder if it does not exist. Mirrors
    append_outbox's create-then-append shape so a missing Drafts folder
    on a fresh mailbox does not fail the call."""
    try:
        client.create_folder('Drafts')
    except: # pylint: disable=bare-except
        pass
    client.append('Drafts', msg.as_string().encode(), flags=[rb"\Draft", rb"\Seen"])

def send(msg, smtp_host):
    """Send the message"""
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
        smtp_client.send_message(msg)
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

def move(msg_id, client):
    """Moves message identified by msg_id from Outbox to Sent"""
    try:
        client.create_folder('Sent')
    except: # pylint: disable=bare-except
        pass
    client.select_folder('Outbox')
    try:
        client.move([msg_id], 'Sent')
    except: # pylint: disable=bare-except
        return False
    return True
