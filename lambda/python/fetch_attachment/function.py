'''Preps an attachment for download from S3 given a mailbox, message ID, and attachment serial number'''
import json
import email
import logging
from shared import upload_object
from shared import sign_url
from datetime import datetime
from email.policy import default as default_policy
from imapclient import IMAPClient

logger = logging.getLogger()
logger.setLevel(logging.INFO)

def handler(event, _context):
    '''Preps an attachment for download from S3 given a mailbox, message ID, and attachment serial number'''
    body = json.loads(event['body'])
    bucket = body['host'].replace("imap", "cache")
    key = f"{body['user']}/{body['mailbox']}/{body['id']}/{body['filename']}"
    # TODO: Check if file is already on s3
    client = IMAPClient(host=body['host'], use_uid=True, ssl=True)
    client.login(body['user'], body['password'])
    client.select_folder(body['mailbox'])
    email_body_raw = client.fetch([body['id']],[b"RFC822"])
    message = email.message_from_bytes(email_body_raw[body['id']][b"RFC822"], policy=default_policy)
    i = 0;
    if message.is_multipart():
        for part in message.walk():
            ct = part.get_content_type()
            if i == body['index']:
                upload_object(bucket, key, ct, part.get_payload(decode=True))
            i += 1
    return {
        "statusCode": 200,
        "body": json.dumps({
            "url": sign_url(bucket, key)
        })
    }
