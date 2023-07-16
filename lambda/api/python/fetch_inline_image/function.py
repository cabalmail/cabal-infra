'''Preps an inline image attachment for download from S3 given a folder, message ID, and attachment uuid'''
import json
from helper import upload_object # pylint: disable=import-error
from helper import sign_url # pylint: disable=import-error
from helper import key_exists # pylint: disable=import-error
from helper import get_object # pylint: disable=import-error
from helper import get_message # pylint: disable=import-error

def handler(event, _context):
    '''Preps an inline image attachment for download from S3 given a folder, message ID, and attachment uuid'''
    qs = event['queryStringParameters']
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    bucket = qs['host'].replace("imap", "cache")
    key = ""
    message = get_message(qs['host'], user, qs['folder'], qs['id'])
    for part in message.walk():
        ct = part.get_content_type()
        if part.get('Content-ID'):
            if part.get('Content-ID') == qs['index']:
                key = f"{user}/{qs['folder']}/{qs['id']}/{qs['index']}/{part.get_filename()}"
                if not key_exists(bucket, key):
                    upload_object(bucket, key, ct, part.get_payload(decode=True))

    return {
        "statusCode": 200,
        "body": json.dumps({
            "url": sign_url(bucket, key)
        })
    }
