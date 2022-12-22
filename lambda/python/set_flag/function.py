'''Sets IMAP flags on messages for a user given a folder and list of message ids'''
import json
from s3 import get_imap_client

def handler(event, _context):
    '''Sets IMAP flags on messages for a user given a folder and list of message ids'''
    body = event['body']
    ids = json.loads(body['ids'])
    user = event['requestContext']['authorizer']['claims']['cognito:username'];
    client = get_imap_client(body['host'], user, body['folder'])
    if body['op'] == 'set':
        client.set_flags(ids, body['flag'], True)
    else:
        client.remove_flags(ids, body['flag'], True)
    response = client.sort(f"{body['sort_order']}{body['sort_field']}", [b'NOT', b'DELETED'])
    client.logout()
    return {
        "statusCode": 200,
        "body": json.dumps({
            "message_ids": response
        })
    }
