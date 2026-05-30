'''Preps an inline image attachment for download from S3 given a folder,
message ID, and attachment uuid'''
import json
from helper import upload_object # pylint: disable=import-error
from helper import sign_url # pylint: disable=import-error
from helper import key_exists # pylint: disable=import-error
from helper import get_message # pylint: disable=import-error
from helper import validate_content_id # pylint: disable=import-error
from helper import validate_folder_name # pylint: disable=import-error
from helper import validate_uid # pylint: disable=import-error

def handler(event, _context):
    '''Preps an inline image attachment for download from S3 given a folder,
    message ID, and attachment uuid'''
    query_string = event.get('queryStringParameters') or {}
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    try:
        folder = validate_folder_name(query_string.get('folder'))
        msg_id = validate_uid(query_string.get('id'))
        index = validate_content_id(query_string.get('index'))
    except ValueError as err:
        return {
            "statusCode": 400,
            "body": json.dumps({"status": f"Invalid input: {err}"})
        }
    bucket = query_string['host'].replace("imap", "cache")
    key_prefix = f"{user}/{folder}/{msg_id}/{index}"
    key = ""
    message = get_message(query_string['host'], user,
                          folder.replace("/", "."), msg_id)
    for part in message.walk():
        content_type = part.get_content_type()
        if part.get('Content-ID'):
            if part.get('Content-ID') == index:
                key = f"{key_prefix}/{part.get_filename()}"
                if not key_exists(bucket, key):
                    upload_object(bucket, key, content_type, part.get_payload(decode=True))

    return {
        "statusCode": 200,
        "body": json.dumps({
            "url": sign_url(bucket, key)
        })
    }
