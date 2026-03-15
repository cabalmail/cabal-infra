'''Retrieves IMAP message ids for a user given a folder and sorting criteria'''
import json
from helper import get_imap_client # pylint: disable=import-error

def handler(event, _context):
    '''Retrieves IMAP message ids for a user given a folder and sorting criteria'''
    query_string = event['queryStringParameters']
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    client = get_imap_client(query_string['host'], user, query_string['folder'].replace("/","."))
    flags = [b'NOT', b'DELETED']
    response = client.sort(f"{query_string['sort_order']}{query_string['sort_field']}", flags)
    client.logout()
    return {
        "statusCode": 200,
        "body": json.dumps({
            "message_ids": response
        })
    }
