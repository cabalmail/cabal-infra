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
    body_plain = ""
    body_html = ""
    if message.is_multipart():
        for part in message.walk():
            ctype = part.get_content_type()
            cdispo = str(part.get('Content-Disposition'))

            # skip any text/plain (txt) attachments
            if ctype == 'text/plain' and 'attachment' not in cdispo:
                body_plain = part.get_payload(decode=True)  # decode
            if ctype == 'text/html' and 'attachment' not in cdispo:
                body_html = part.get_payload(decode=True)  # decode
    else:
        body_plain = message.get_payload(decode=True)
    client.logout()
    return {
        "statusCode": 200,
        "body": json.dumps({
            "data": {
              "message_raw": message.__str__(),
              "message_body_plain": body_plain.decode(),
              "message_body_html": body_html.decode()
            }
        })
    }
    