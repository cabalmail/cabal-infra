'''Sets IMAP flags on messages for a user given a folder and list of message ids'''
import json
from helper import get_imap_client # pylint: disable=import-error

def handler(event, _context):
    '''Sets IMAP flags on messages for a user given a folder and list of message ids'''
    body = json.loads(event['body'])
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    client = get_imap_client(body['host'], user, body['source'])
    if body['destination'] == "Deleted Messages":
        try:
            client.create_folder(body['destination'])
        except:
            pass
    try:
        client.move(body['ids'], body['destination'])
    except:
        client.logout()
        return {
            "statusCode": 500,
            "body": json.dumps({
                "status": "unable"
            })
        }
    client.logout()
    return {
        "statusCode": 200,
        "body": json.dumps({
            "status": "submitted"
        })
    }
