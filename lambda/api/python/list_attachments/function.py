'''Retrieves list of attachments from a message given a folder and ID'''
import json
from helper import get_message # pylint: disable=import-error

def handler(event, _context):
    '''Retrieves list of attachments from a message given a folder and ID'''
    qs = event['queryStringParameters']
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    message = get_message(qs['host'], user, qs['folder'], int(qs['id']))
    attachments = []
    i = 0;
    if message.is_multipart():
        for part in message.walk():
            ct = part.get_content_type()
            cd = str(part.get('Content-Disposition'))
            if 'attachment' in cd:
                attachments.append({
                    "name": part.get_filename(),
                    "type": part.get_content_type(),
                    "size": len(part.get_payload(decode=True)),
                    "id": i
                })
            i += 1
    return {
        "statusCode": 200,
        "body": json.dumps({
            "attachments": attachments
        })
    }
