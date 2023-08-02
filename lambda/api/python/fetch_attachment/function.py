'''Preps an attachment for download from S3 given a folder, message ID,
and attachment serial number'''
import json
from helper import upload_object # pylint: disable=import-error
from helper import sign_url # pylint: disable=import-error
from helper import key_exists # pylint: disable=import-error
from helper import get_message # pylint: disable=import-error

def handler(event, _context):
    '''Preps an attachment for download from S3 given a folder, message ID,
    and attachment serial number'''
    query_string = event['queryStringParameters']
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    bucket = query_string['host'].replace("imap", "cache")
    key = f"{user}/{query_string['folder']}/{query_string['id']}/{query_string['filename']}"
    index = int(query_string['index'])
    message = get_message(query_string['host'], user, query_string['folder'].replace("/","."), query_string['id'])
    i = 0
    if message.is_multipart():
        for part in message.walk():
            content_type = part.get_content_type()
            if i == index:
                if not key_exists(bucket, key):
                    upload_object(bucket, key, content_type, part.get_payload(decode=True))
            i += 1
    return {
        "statusCode": 200,
        "body": json.dumps({
            "url": sign_url(bucket, key)
        })
    }
