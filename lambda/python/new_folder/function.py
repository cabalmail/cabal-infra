'''Sets IMAP flags on messages for a user given a folder and list of message ids'''
import json
from s3 import get_imap_client
from s3 import get_folder_list

def handler(event, _context):
    '''Creates a new folder and returns updated folder list'''
    body = json.loads(event['body'])
    user = event['requestContext']['authorizer']['claims']['cognito:username'];
    client = get_imap_client(body['host'], user, body['parent'])
    client.create_folder(body['name'])
    response = client.get_folder_list(client)
    client.logout()
    return {
        "statusCode": 201,
        "body": json.dumps(response)
    }
