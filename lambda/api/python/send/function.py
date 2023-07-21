'''Sends an email message'''
import json
from email.message import EmailMessage # pylint: disable=import-error
from helper import get_imap_client # pylint: disable=import-error
# Flow:
     # - place in outbox
     # - send via SMTP
     # - on succes, move from outbox to Sent

def handler(event, _context):
    '''Sends an email message'''
    body = json.loads(event['body'])
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    client = get_imap_client(body['host'], user, 'INBOX')
    msg = EmailMessage()
    msg['Subject'] = body['subject']
    msg['From'] = body['sender']
    msg['To'] = ','.join(body['to_list'])
    msg['Cc'] = ','.join(body['cc_list'])
    msg['Bcc'] = ','.join(body['bcc_list'])
    msg.set_content("This is a Multi-part message.")
    msg.add_alternative(body['body'], subtype='html')
    try:
        client.create_folder('Outbox')
    except: # pylint: disable=bare-except
        pass
    client.append('Outbox',msg)
    client.logout()
    return {
        "statusCode": 200,
        "body": json.dumps({
            "status": "submitted"
        })
    }
