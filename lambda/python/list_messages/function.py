'''Retrieves IMAP message ids for a user given a folder and sorting criteria'''
import json
from s3 import get_imap_client

def handler(event, _context):
    '''Retrieves IMAP message ids for a user given a folder and sorting criteria'''
    qs = json.loads(event['queryStringParameters'])
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

