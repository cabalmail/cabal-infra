'''Sends an email message'''
import json
import smtplib
from email.message import EmailMessage
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
    msg = EmailMessage()
    msg['Subject'] = body['subject']
    msg['From'] = body['sender']
    msg['To'] = ','.join(body['to_list'])
    msg['Cc'] = ','.join(body['cc_list'])
    msg['Bcc'] = ','.join(body['bcc_list'])
    msg.set_content(body['text'], subtype='plain')
    msg.add_alternative(body['html'], subtype='html')

    # Place in Outbox
    client = get_imap_client(body['host'], user, 'INBOX')
    try:
        client.create_folder('Outbox')
    except: # pylint: disable=bare-except
        pass
    client.append('Outbox',msg.as_string().encode())

    # Send
    server = smtplib.SMTP_SSL(body['smtp_host'])
    try:
        server.login("master", get_mpw())
    except smtplib.SMTPHeloError:
        return {
            "statusCode": 500,
            "body": json.dumps({
                "status": "SMTP server did not respond correctly to Helo"
            })
        }
    except smtplib.SMTPAuthenticationError:
        return {
            "statusCode": 401,
            "body": json.dumps({
                "status": "SMTP server did not accept our credentials"
            })
        }
    except smtplib.SMTPNotSupportedError:
        # The AUTH command is not supported by the server.
        return {
            "statusCode": 501,
            "body": json.dumps({
                "status": "Server does not support our auth type"
            })
        }
    except smtplib.SMTPException:
        return {
            "statusCode": "500",
            "body": json.dumps({
                "status": "Other SMTP exception while authenticating"
            })
        }
    except:
        return {
            "statusCode": "500",
            "body": json.dumps({
                "status": "Unknown error trying to authenticate to SMTP server"
            })
        }
    try:
        server.send_message(msg)
    except smtplib.SMTPRecipientsRefused:
        return {
            "statusCode": 401,
            "body": json.dumps({
                "status": "SMTP server rejected recipient list; mail not sent",
                "additionalInfo": SMTPRecipientsRefused
            })
        }
    except smtplib.SMTPHeloError:
        return {
            "statusCode": 500,
            "body": json.dumps({
                "status": "SMTP server did not respond correctly to Helo"
            })
        }
    except smtplib.SMTPSenderRefused:
        return {
            "statusCode": 401,
            "body": json.dumps({
                "status": "SMTP server rejected the sender"
                })
        }
    except smtplib.SMTPDataError:
        return {
            "statusCode": 500,
            "body": json.dumps({
                "status": "SMTP server rejected us after accepting our sender and recipients"
            })
        }
    except smtplib.SMTPNotSupportedError:
        return {
            "statusCode": "500",
            "body": json.dumps({
                "status": "Other SMTP exception while sending"
            })
        }
    except:
        return {
            "statusCode": "500",
            "body": json.dumps({
                "status": "Unknown error trying to send the message"
            })
        }
    server.quit()

    # Move to Sent box
    client.logout()
    return {
        "statusCode": 200,
        "body": json.dumps({
            "status": "submitted"
        })
    }
