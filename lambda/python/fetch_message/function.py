'''Retrieves IMAP message given a mailbox and ID'''
import json
# import logging
from datetime import datetime
import email
from email.policy import default as default_policy

from imapclient import IMAPClient

# logger = logging.getLogger()
# logger.setLevel(logging.INFO)

def handler(event, _context):
    '''Retrieves IMAP message given a mailbox and ID'''
    body = json.loads(event['body'])
    client = IMAPClient(host=body['host'], use_uid=True, ssl=True)
    client.login(body['user'], body['password'])
    client.select_folder(body['mailbox'])
    email_body_raw = client.fetch([body['id']],[b"RFC822"])
    message = email.message_from_bytes(email_body_raw[body['id']][b"RFC822"], policy=default_policy)
    body_plain = ""
    body_html = ""
    if message.is_multipart():
        for part in message.walk():
            ct = part.get_content_type()
            cd = str(part.get('Content-Disposition'))
            if ct == 'text/plain' and 'attachment' not in cd:
                body_plain = part.get_payload(decode=True)
            if ct == 'text/html' and 'attachment' not in cd:
                body_html = part.get_payload(decode=True)
    else:
        ct = message.get_content_type()
        if ct == 'text/plain':
            body_plain = message.get_payload(decode=True)
        if ct == 'text/html':
            body_html = message.get_payload(decode=True)

    try:
        body_html_decoded = body_html.decode()
    except AttributeError:
        body_html_decoded = body_html.__str__()
    try:
        body_plain_decoded = body_plain.decode()
    except AttributeError:
        body_plain_decoded = body_plain.__str__()
    if len(message.__str__()) > 1000000:
        message = "Raw message too large to display"
    return {
        "statusCode": 200,
        "body": json.dumps({
            "message_raw": message.__str__(),
            "message_body_plain": body_plain_decoded,
            "message_body_html": body_html_decoded
        })
    }
