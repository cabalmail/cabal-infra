'''Retrieves IMAP message ids for a user given a folder and sorting criteria'''
import json
from helper import get_imap_client

def handler(event, _context):
    '''Retrieves IMAP message ids for a user given a folder and sorting criteria'''
    qs = event['queryStringParameters']
    user = event['requestContext']['authorizer']['claims']['cognito:username'];
    client = get_imap_client(qs['host'], user, qs['folder'])
    response = client.sort(f"{qs['sort_order']}{qs['sort_field']}", [b'NOT', b'DELETED'])
    client.logout()
    return {
        "statusCode": 200,
        "body": json.dumps({
            "message_ids": response
        })
    }

