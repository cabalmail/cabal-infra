'''Preps an attachment for download from S3 given a folder, message ID, and attachment serial number'''
import json
from s3 import upload_object
from s3 import sign_url
from s3 import key_exists
from s3 import get_object
from s3 import get_message

def handler(event, _context):
    '''Preps an attachment for download from S3 given a folder, message ID, and attachment serial number'''
    qs = event['queryStringParameters']
    user = event['requestContext']['authorizer']['claims']['cognito:username'];
    bucket = qs['host'].replace("imap", "cache")
    key = f"{user}/{qs['folder']}/{qs['id']}/{qs['filename']}"
    message = get_message(qs['host'], user, qs['folder'], qs['id'])
    i = 0;
    if message.is_multipart():
        for part in message.walk():
            ct = part.get_content_type()
            if i == qs['index']:
                if not key_exists(bucket, key):
                    upload_object(bucket, key, ct, part.get_payload(decode=True))
            i += 1
    return {
        "statusCode": 200,
        "body": json.dumps({
            "url": sign_url(bucket, key)
        })
    }
