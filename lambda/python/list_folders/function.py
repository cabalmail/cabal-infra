'''Retrieves IMAP folders for a user'''
import json
from s3 import get_imap_client
from s3 import get_folder_list

def handler(event, _context):
    '''Retrieves IMAP folders for a user'''
    qs = event['queryStringParameters']
    user = event['requestContext']['authorizer']['claims']['cognito:username'];
    client = get_imap_client(qs['host'], user, 'INBOX')
    response = client.get_folder_list(client)
    client.logout()
    return {
        "statusCode": 200,
        "body": json.dumps(response)
    }
