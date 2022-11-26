'''Retrieves list of attachments from a message given a mailbox and ID'''
import json
# import logging
from datetime import datetime
import email
from email.policy import default as default_policy

from imapclient import IMAPClient

# logger = logging.getLogger()
# logger.setLevel(logging.INFO)

def handler(event, _context):
    '''Retrieves list of attachments from a message given a mailbox and ID'''
    body = json.loads(event['body'])
    client = IMAPClient(host=body['host'], use_uid=True, ssl=True)
    client.login(body['user'], body['password'])
    client.select_folder(body['mailbox'])
    email_body_raw = client.fetch([body['id']],[b"RFC822"])
    message = email.message_from_bytes(email_body_raw[body['id']][b"RFC822"], policy=default_policy)
    attachments = []
    if message.is_multipart():
        for part in message.walk():
            ct = part.get_content_type()
            cd = str(part.get('Content-Disposition'))
            if 'attachment' in cd:
                attachments.append({
                    name: part.get_filename().decode(),
                    type: part.get_content_type().decode(),
                })
    return {
        "statusCode": 200,
        "body": json.dumps({
            "data": {
                "attachments": attachments
            }
        })
    }
