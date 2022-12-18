'''Preps an inline image attachment for download from S3 given a mailbox, message ID, and attachment uuid'''
import json
import logging
from s3 import upload_object
from s3 import sign_url
from s3 import key_exists
from s3 import get_object
from s3 import get_message

logger = logging.getLogger()
logger.setLevel(logging.INFO)

def handler(event, _context):
    '''Preps an inline image attachment for download from S3 given a mailbox, message ID, and attachment uuid'''
    body = json.loads(event['body'])
    bucket = body['host'].replace("imap", "cache")
    key = ""
    message = get_message(body['host'], body['user'], body['password'], body['mailbox'], body['id'])
    for part in message.walk():
        ct = part.get_content_type()
        if part.get('Content-ID'):
            if part.get('Content-ID') == body['index']:
                key = f"{body['user']}/{body['mailbox']}/{body['id']}/{body['index']}/{part.get_filename()}"
                if not key_exists(bucket, key):
                    upload_object(bucket, key, ct, part.get_payload(decode=True))

    logger.info(f"Key is {key}")
    return {
        "statusCode": 200,
        "body": json.dumps({
            "url": sign_url(bucket, key)
        })
    }
