'''Retrieves IMAP message given a mailbox and ID'''
import json
import logging
from datetime import datetime
import email
from email.policy import default as default_policy

from imapclient import IMAPClient

logger = logging.getLogger()
logger.setLevel(logging.INFO)

def handler(event, _context):
    '''Retrieves IMAP message given a mailbox and ID'''
    client = IMAPClient(host="imap.${control_domain}", use_uid=True, ssl=True)
    body = json.loads(event['body'])
    client.login(body['user'], body['password'])
    client.select_folder(body['mailbox'])
    email_body_raw = client.fetch([body['id']],[b"RFC822"])
    message = email.message_from_bytes(email_body_raw[body['id']][b"RFC822"], policy=default_policy)
    client.logout()
    return {
        "statusCode": 200,
        "body": json.dumps({
            "data": {
              "message_raw": message.__str__(),
              "message_body": message.get_body().__str__()
            }
        })
    }
