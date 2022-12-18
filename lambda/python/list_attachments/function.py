'''Retrieves list of attachments from a message given a mailbox and ID'''
import json
# import logging
from s3 import get_message
# logger = logging.getLogger()
# logger.setLevel(logging.INFO)

def handler(event, _context):
    '''Retrieves list of attachments from a message given a mailbox and ID'''
    body = json.loads(event['body'])
    message = get_message(body['host'], body['user'], body['password'], body['mailbox'], body['id'])
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
