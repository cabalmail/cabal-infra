'''Sets IMAP flags on messages for a user given a folder and list of message ids'''
import json
from s3 import get_imap_client

def handler(event, _context):
    '''Sets IMAP flags on messages for a user given a folder and list of message ids'''
    qs = event['queryStringParameters']
    ids = json.loads(qs['ids'])
    user = event['requestContext']['authorizer']['claims']['cognito:username'];
    client = get_imap_client(qs['host'], user, qs['folder'])
    if qs['op'] == 'set':
        client.set_flags(ids, qs['flag'], True)
    else:
        client.remove_flags(ids, qs['flag'], True)
    response = client.sort(f"{qs['sort_order']}{qs['sort_field']}", [b'NOT', b'DELETED'])
    client.logout()
    return {
        "statusCode": 200,
        "body": json.dumps({
            "message_ids": response
        })
    }
