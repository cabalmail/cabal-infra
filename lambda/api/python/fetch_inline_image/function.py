'''Preps an inline image attachment for download from S3 given a folder,
message ID, and attachment uuid'''
import json
from helper import upload_object # pylint: disable=import-error
from helper import sign_url # pylint: disable=import-error
from helper import key_exists # pylint: disable=import-error
from helper import get_message # pylint: disable=import-error

def handler(event, _context):
    '''Preps an inline image attachment for download from S3 given a folder,
    message ID, and attachment uuid'''
    query_string = event['queryStringParameters']
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    bucket = query_string['host'].replace("imap", "cache")
    key_prefix = f"{user}/{query_string['folder']}/{query_string['id']}/{query_string['index']}"
    key = ""
    message = get_message(query_string['host'], user,
                          query_string['folder'].replace("/","."), query_string['id'])
    for part in message.walk():
        content_type = part.get_content_type()
        if part.get('Content-ID'):
            if part.get('Content-ID') == query_string['index']:
                key = f"{key_prefix}/{part.get_filename()}"
                if not key_exists(bucket, key):
                    upload_object(bucket, key, content_type, part.get_payload(decode=True))

    return {
        "statusCode": 200,
        "body": json.dumps({
            "url": sign_url(bucket, key)
        })
    }
