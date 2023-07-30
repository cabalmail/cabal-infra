'''Sends an email message'''
import json
import smtplib
from email.message import EmailMessage
from email.utils import formatdate
from helper import get_imap_client # pylint: disable=import-error
from helper import get_mpw # pylint: disable=import-error
from helper import user_authorized_for_sender # pyling: disable=import-error

def handler(event, _context):
    '''Sends an email message'''

    # Compose message
    body = json.loads(event['body'])
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    # TODO: Check if user is authorized to send on behalf of body['sender'] # pylint: disable=fixme
    if not user_authorized_for_sender(user, body['sender']):
        return {
            "statusCode": 500,
            "body": json.dumps({
                "status": "Sender address not associated with authenticated user"
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
                          body['text'], body['html'])

    # Establish IMAP connection
    client = get_imap_client(body['host'], user, 'INBOX')

    # Place in Outbox
    msg_id = append_outbox(msg, client)

    # Send
    return_from_send = send(msg, body['smtp_host'])
    if return_from_send['statusCode'] != 200:
        return return_from_send

    # Move to Sent box
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

def compose_message(subject, sender, headers, text, html):
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
