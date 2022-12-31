'''Sets IMAP flags on messages for a user given a folder and list of message ids'''
import json
from s3 import get_imap_client

def handler(event, _context):
    '''Sets IMAP flags on messages for a user given a folder and list of message ids'''
    body = json.loads(event['body'])
    user = event['requestContext']['authorizer']['claims']['cognito:username'];
    client = get_imap_client(body['host'], user, body['parent'])
    response = client.create_folder(body['name'])
    client.logout()
    return {
        "statusCode": 201,
        "body": json.dumps({
            "message_ids": response
        })
    }
