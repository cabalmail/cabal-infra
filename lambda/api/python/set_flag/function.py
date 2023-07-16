'''Sets IMAP flags on messages for a user given a folder and list of message ids'''
import json
from helper import get_imap_client # pylint: disable=import-error

def handler(event, _context):
    '''Sets IMAP flags on messages for a user given a folder and list of message ids'''
    body = json.loads(event['body'])
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    client = get_imap_client(body['host'], user, body['folder'])
    if body['op'] == 'set':
        client.add_flags(body['ids'], body['flag'], True)
    else:
        client.remove_flags(body['ids'], body['flag'], True)
    response = client.sort(f"{body['sort_order']}{body['sort_field']}", [b'NOT', b'DELETED'])
    client.logout()
    return {
        "statusCode": 200,
        "body": json.dumps({
            "message_ids": response
        })
    }
