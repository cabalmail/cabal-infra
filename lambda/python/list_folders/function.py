'''Retrieves IMAP folders for a user'''
import json
from helper import get_imap_client
from helper import get_folder_list

def handler(event, _context):
    '''Retrieves IMAP folders for a user'''
    qs = event['queryStringParameters']
    user = event['requestContext']['authorizer']['claims']['cognito:username'];
    client = get_imap_client(qs['host'], user, 'INBOX')
    response = get_folder_list(client)
    client.logout()
    return {
        "statusCode": 200,
        "body": json.dumps(response)
    }
