'''Sends an email message'''
import json
import smtplib
from email.message import EmailMessage
from email.utils import formatdate
from helper import get_imap_client # pylint: disable=import-error
from helper import get_mpw # pylint: disable=import-error
# Flow:
     # - place in outbox
     # - send via SMTP
     # - on succes, move from outbox to Sent

def handler(event, _context):
    '''Sends an email message'''

    # Compose message
    body = json.loads(event['body'])
    user = event['requestContext']['authorizer']['claims']['cognito:username']

    msg = compose_message(body['subject'], body['sender'], {"to": ','.join(body['to_list']),
                          "cc": ','.join(body['cc_list']), "bcc": ','.join(body['bcc_list']) },
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

def compose_message(subject, sender, recipients, text, html):
    """Create a message object"""
    msg = EmailMessage()
    msg['Subject'] = subject
    msg['From'] = sender
    if len(recipients['to']):
        msg['To'] = recipients['to']
    if len(recipients['cc']):
        msg['Cc'] = recipients['cc']
    if len(recipients['bcc']):
        msg['Bcc'] = recipients['bcc']
    msg['Date'] = formatdate(localtime=True)
    msg.set_content(text, subtype='plain')
    msg.add_alternative(html, subtype='html')
    return msg

def append_outbox(msg, client):
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
