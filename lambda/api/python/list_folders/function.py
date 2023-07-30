'''Retrieves IMAP folders for a user'''
import json
from helper import get_imap_client # pylint: disable=import-error
from helper import get_folder_list # pylint: disable=import-error

def handler(event, _context):
    '''Retrieves IMAP folders for a user'''
    query_string = event['queryStringParameters']
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    client = get_imap_client(query_string['host'], user, 'INBOX')
    response = get_folder_list(client)
    client.logout()
    return {
        "statusCode": 200,
        "body": json.dumps(response)
    }
