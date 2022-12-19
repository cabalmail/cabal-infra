'''Preps an attachment for download from S3 given a mailbox, message ID, and attachment serial number'''
import json
from s3 import upload_object
from s3 import sign_url
from s3 import key_exists
from s3 import get_object
from s3 import get_message

def handler(event, _context):
    '''Preps an attachment for download from S3 given a mailbox, message ID, and attachment serial number'''
    body = json.loads(event['body'])
    bucket = body['host'].replace("imap", "cache")
    key = f"{body['user']}/{body['mailbox']}/{body['id']}/{body['filename']}"
    message = get_message(body['host'], body['user'], body['password'], body['mailbox'], body['id'])
    i = 0;
    if message.is_multipart():
        for part in message.walk():
            ct = part.get_content_type()
            if i == body['index']:
                if not key_exists(bucket, key):
                    upload_object(bucket, key, ct, part.get_payload(decode=True))
            i += 1
    return {
        "statusCode": 200,
        "body": json.dumps({
            "url": sign_url(bucket, key)
        })
    }
